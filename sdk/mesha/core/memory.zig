//! Memory for the host and its plugins: page accounting, scopes, arenas and scratch.
//!
//! A `Memory` is the host's, made once at a stable address (`Memory.init`). Every page it hands out
//! comes from its one `PageSource` and is charged to a `Scope`: a named lifetime its owner opens
//! (`Memory.openScope`, `openChildScope`, or a private one) and later releases. A scope has a fixed
//! arena for records that live as long as it does (`Scope.fixedAllocator`), dynamic arenas that
//! return their pages when released (`Scope.createArena`, `labeledArena`), and direct page backing
//! for owners that manage their own pages, such as table storage (`Scope.backingAllocator`).
//! `PageBacking` counts the page-rounded bytes of each, and `Memory.syncTable` reports them in the
//! `memory` table.
//!
//! `Arena` is the bump arena all of these are. Scratch is two arenas of the `host.work` scope: the
//! frame's (`Memory.frameScratchAllocator`, valid until the host's next `Memory.beginFrame`) and
//! the tables' (`Memory.tableScratchAllocator`, valid until the next call of it).
//!
//! The host and each plugin are separate images, each with its own compiled copy of this code. A
//! `std.mem.Allocator` points at a vtable in the image that made it, so one is used where it is
//! made and never kept where another image may call it. `PageBacking` and `Arena` hold no
//! allocator, so either image may call them, and their `allocator()` resolves in the calling image.
//! `SharedAllocator` is the allocator that may be kept and called from any image.
//!
//! An init admission (`Memory.beginInitAdmission`) brackets a setup of several steps that either
//! commits whole or aborts: an abort destroys the scopes and dynamic arenas made inside it, and a
//! release of what existed before it is refused and rejects the admission.
const std = @import("std");
const Atom = @import("atom.zig").Atom;
const Table = @import("table.zig");

/// An allocator for scratch: short-lived storage that ends when its owner says, never freed piece
/// by piece.
pub const Scratch = struct {
    /// Valid in the image that made it, until the scratch behind it is reset: see
    /// `Memory.frameScratchAllocator` and `Memory.tableScratchAllocator`.
    allocator: std.mem.Allocator,
};

/// Where pages come from: the system's page allocator, which keeps no state of its own, so the
/// code of either image may call it for pages the other frees. A test may refuse requests from
/// an index on, as `std.testing.FailingAllocator` does. Every scope of a Memory shares one, and
/// they may allocate on different threads.
pub const PageSource = struct {
    /// Allocations granted so far.
    allocations: std.atomic.Value(usize) = .init(0),
    /// Allocations freed so far.
    deallocations: std.atomic.Value(usize) = .init(0),
    /// Resizes and remaps granted so far.
    resizes: std.atomic.Value(usize) = .init(0),
    /// The first allocation refused: every one from it on is refused.
    fail_index: std.atomic.Value(usize) = .init(std.math.maxInt(usize)),
    /// The first resize or remap refused: every one from it on is refused.
    resize_fail_index: std.atomic.Value(usize) = .init(std.math.maxInt(usize)),
    /// Whether `fail_index` or `resize_fail_index` has refused a request: a refusal the test asked
    /// for, as distinct from the system running out.
    has_induced_failure: std.atomic.Value(bool) = .init(false),

    /// Refuses every allocation after the next `count`. Resizes and remaps are not affected.
    pub fn refuseAfter(source: *PageSource, count: usize) void {
        const granted = source.allocations.load(.monotonic);
        source.fail_index.store(granted + count, .monotonic);
    }

    /// Refuses every resize and remap after the next `count`.
    pub fn refuseResizesAfter(source: *PageSource, count: usize) void {
        const granted = source.resizes.load(.monotonic);
        source.resize_fail_index.store(granted + count, .monotonic);
    }

    /// Grants every request again, undoing `refuseAfter` and `refuseResizesAfter`.
    /// `has_induced_failure` keeps its value.
    pub fn refuseNone(source: *PageSource) void {
        source.fail_index.store(std.math.maxInt(usize), .monotonic);
        source.resize_fail_index.store(std.math.maxInt(usize), .monotonic);
    }

    fn alloc(source: *PageSource, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        if (source.allocations.load(.monotonic) >= source.fail_index.load(.monotonic)) {
            source.has_induced_failure.store(true, .monotonic);
            return null;
        }
        const result = std.heap.page_allocator.rawAlloc(len, alignment, return_address) orelse return null;
        _ = source.allocations.fetchAdd(1, .monotonic);
        return result;
    }

    fn resizeRefused(source: *PageSource) bool {
        if (source.resizes.load(.monotonic) < source.resize_fail_index.load(.monotonic)) return false;
        source.has_induced_failure.store(true, .monotonic);
        return true;
    }

    fn resize(source: *PageSource, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) bool {
        if (source.resizeRefused()) return false;
        if (!std.heap.page_allocator.rawResize(memory, alignment, new_len, return_address)) return false;
        _ = source.resizes.fetchAdd(1, .monotonic);
        return true;
    }

    fn remap(source: *PageSource, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
        if (source.resizeRefused()) return null;
        const result = std.heap.page_allocator.rawRemap(memory, alignment, new_len, return_address) orelse return null;
        _ = source.resizes.fetchAdd(1, .monotonic);
        return result;
    }

    fn free(source: *PageSource, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        std.heap.page_allocator.rawFree(memory, alignment, return_address);
        _ = source.deallocations.fetchAdd(1, .monotonic);
    }
};

/// Thin accounting context over a page source. Scope arenas allocate through it
/// directly, so destroying one arena returns its pages rather than leaving them with
/// a parent. Counters are logical page-rounded backing bytes: not RSS, and not OS
/// commit charge. Windows keeps a shrunken allocation's pages committed until it is
/// freed, so the counter can fall below the OS commit there.
/// It holds no allocator: its code, in whichever image calls it, reaches the source directly.
/// The address must stay stable while any allocator from `allocator()` is live.
pub const PageBacking = struct {
    /// A backing's charge in page-rounded bytes: `current_bytes` held at the moment, and
    /// `peak_bytes`, the most ever held.
    pub const Stats = struct { current_bytes: u64, peak_bytes: u64 };

    /// Where its pages come from: a source, or another backing charged for them too, as a
    /// scope's pages are for its direct backing.
    upstream: Upstream,
    // Arenas sharing one context may run on different threads.
    /// Page-rounded bytes held at the moment.
    current_bytes: std.atomic.Value(u64) = .init(0),
    /// The most `current_bytes` has been.
    peak_bytes: std.atomic.Value(u64) = .init(0),

    /// Where a backing takes its pages from.
    pub const Upstream = union(enum) {
        /// The page source itself, as a scope's `pages` has.
        source: *PageSource,
        /// Another backing, charged for the same bytes, as a scope's `direct` has its `pages`.
        parent: *PageBacking,
    };

    /// The `std.mem.Allocator` functions over a backing, in the image this code is compiled into;
    /// `allocator` uses it.
    pub const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    /// Resolves in the calling image: for use there and then, never to be kept where another
    /// image may call it.
    pub fn allocator(self: *PageBacking) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// The bytes held and their peak. Observation only, and safe while other threads allocate: the
    /// peak reported is never below the current.
    pub fn stats(self: *const PageBacking) Stats {
        const current_bytes = self.current_bytes.load(.monotonic);
        const peak_bytes = self.peak_bytes.load(.monotonic);
        // A concurrent allocation may have raised current but not yet peak.
        return .{ .current_bytes = current_bytes, .peak_bytes = @max(current_bytes, peak_bytes) };
    }

    /// Null when rounding `len` up to a page is not representable.
    fn roundedBytes(len: usize) ?u64 {
        const page_size = std.heap.pageSize();
        const padded = std.math.add(usize, len, page_size - 1) catch return null;
        return std.mem.alignBackward(usize, padded, page_size);
    }

    fn recordGrowth(self: *PageBacking, bytes: u64) void {
        const previous = self.current_bytes.fetchAdd(bytes, .monotonic);
        _ = self.peak_bytes.fetchMax(previous + bytes, .monotonic);
    }

    fn recordRelease(self: *PageBacking, bytes: u64) void {
        const previous = self.current_bytes.fetchSub(bytes, .monotonic);
        std.debug.assert(previous >= bytes);
    }

    fn recordResize(self: *PageBacking, old_bytes: u64, new_bytes: u64) void {
        if (new_bytes >= old_bytes) {
            self.recordGrowth(new_bytes - old_bytes);
        } else {
            self.recordRelease(old_bytes - new_bytes);
        }
    }

    /// Takes `len` bytes of pages from upstream and charges them, rounded up to a page. Null, with
    /// nothing charged, when upstream refuses or `len` cannot be rounded up to a page.
    pub fn rawAlloc(self: *PageBacking, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const bytes = roundedBytes(len) orelse return null;
        const result = switch (self.upstream) {
            .source => |source| source.alloc(len, alignment, return_address),
            .parent => |parent| parent.rawAlloc(len, alignment, return_address),
        } orelse return null;
        self.recordGrowth(bytes);
        return result;
    }

    /// Resizes `memory`, an allocation of this backing at `alignment`, in place, and charges the
    /// difference in rounded bytes. False, with nothing changed, when upstream refuses or `new_len`
    /// cannot be rounded up to a page.
    pub fn rawResize(self: *PageBacking, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) bool {
        const old_bytes = roundedBytes(memory.len).?;
        const new_bytes = roundedBytes(new_len) orelse return false;
        const resized = switch (self.upstream) {
            .source => |source| source.resize(memory, alignment, new_len, return_address),
            .parent => |parent| parent.rawResize(memory, alignment, new_len, return_address),
        };
        if (!resized) return false;
        self.recordResize(old_bytes, new_bytes);
        return true;
    }

    /// As `rawResize`, but the allocation may move: returns where it is, or null with nothing
    /// changed when upstream refuses.
    pub fn rawRemap(self: *PageBacking, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
        const old_bytes = roundedBytes(memory.len).?;
        const new_bytes = roundedBytes(new_len) orelse return null;
        const result = switch (self.upstream) {
            .source => |source| source.remap(memory, alignment, new_len, return_address),
            .parent => |parent| parent.rawRemap(memory, alignment, new_len, return_address),
        } orelse return null;
        self.recordResize(old_bytes, new_bytes);
        return result;
    }

    /// Returns `memory`, an allocation of this backing at `alignment`, to upstream, and takes its
    /// rounded bytes off the charge.
    pub fn rawFree(self: *PageBacking, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const bytes = roundedBytes(memory.len).?;
        switch (self.upstream) {
            .source => |source| source.free(memory, alignment, return_address),
            .parent => |parent| parent.rawFree(memory, alignment, return_address),
        }
        self.recordRelease(bytes);
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        const self: *PageBacking = @ptrCast(@alignCast(context));
        return self.rawAlloc(len, alignment, return_address);
    }

    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) bool {
        const self: *PageBacking = @ptrCast(@alignCast(context));
        return self.rawResize(memory, alignment, new_len, return_address);
    }

    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
        const self: *PageBacking = @ptrCast(@alignCast(context));
        return self.rawRemap(memory, alignment, new_len, return_address);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        const self: *PageBacking = @ptrCast(@alignCast(context));
        self.rawFree(memory, alignment, return_address);
    }
};

/// An allocator the code of any image may call and keep: its functions take C's calling
/// convention. Whoever makes one keeps its functions mapped while it lives, so what a plugin
/// keeps across a reload the host makes. `allocator` adapts it to `std.mem.Allocator` in the
/// calling image, for use there and then, never to be kept where another image may call it.
pub const SharedAllocator = struct {
    /// What `vtable`'s functions take first: the allocator or arena they call. It must outlive this
    /// value and what is made of it.
    context: *anyopaque,
    /// The functions, in the image that made this value, which keeps them mapped while it is used.
    vtable: *const VTable,

    /// `alignment` is a `std.mem.Alignment`'s value.
    pub const VTable = struct {
        /// As `std.mem.Allocator.VTable.alloc`: `len` bytes, or null.
        alloc: *const fn (context: *anyopaque, len: usize, alignment: u8, return_address: usize) callconv(.c) ?[*]u8,
        /// As `std.mem.Allocator.VTable.resize`, the allocation given as its address and `len`:
        /// whether it was resized in place.
        resize: *const fn (context: *anyopaque, memory: [*]u8, len: usize, alignment: u8, new_len: usize, return_address: usize) callconv(.c) bool,
        /// As `std.mem.Allocator.VTable.remap`, the allocation given as its address and `len`:
        /// where it is, or null when it could not be resized.
        remap: *const fn (context: *anyopaque, memory: [*]u8, len: usize, alignment: u8, new_len: usize, return_address: usize) callconv(.c) ?[*]u8,
        /// As `std.mem.Allocator.VTable.free`, the allocation given as its address and `len`.
        free: *const fn (context: *anyopaque, memory: [*]u8, len: usize, alignment: u8, return_address: usize) callconv(.c) void,
    };

    /// Shares `source`, which must outlive what is made of it, through functions of the image
    /// that calls this.
    pub fn wrap(source: *const std.mem.Allocator) SharedAllocator {
        return .{ .context = @constCast(source), .vtable = &Forward.vtable };
    }

    /// Shares `arena`, which must outlive what is made of it, through functions of the image
    /// that calls this.
    pub fn ofArena(arena: *Arena) SharedAllocator {
        return .{ .context = arena, .vtable = &ArenaForward.vtable };
    }

    /// A `std.mem.Allocator` over this, with the calling image's functions. It points at `self`,
    /// which must stay at its address while the allocator is used.
    pub fn allocator(self: *const SharedAllocator) std.mem.Allocator {
        return .{ .ptr = @constCast(self), .vtable = &Adapter.vtable };
    }

    /// Calls a `memory.Arena` for the C functions.
    const ArenaForward = struct {
        const vtable: VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

        fn arenaOf(context: *anyopaque) *Arena {
            return @ptrCast(@alignCast(context));
        }

        fn alloc(context: *anyopaque, len: usize, alignment: u8, return_address: usize) callconv(.c) ?[*]u8 {
            _ = return_address;
            const arena = arenaOf(context);
            return arena.rawAlloc(len, alignmentOf(alignment));
        }

        fn resize(context: *anyopaque, memory: [*]u8, len: usize, alignment: u8, new_len: usize, return_address: usize) callconv(.c) bool {
            _ = alignment;
            _ = return_address;
            const arena = arenaOf(context);
            return arena.rawResize(memory[0..len], new_len);
        }

        fn remap(context: *anyopaque, memory: [*]u8, len: usize, alignment: u8, new_len: usize, return_address: usize) callconv(.c) ?[*]u8 {
            if (resize(context, memory, len, alignment, new_len, return_address)) return memory;
            return null;
        }

        fn free(context: *anyopaque, memory: [*]u8, len: usize, alignment: u8, return_address: usize) callconv(.c) void {
            _ = alignment;
            _ = return_address;
            const arena = arenaOf(context);
            arena.rawFree(memory[0..len]);
        }
    };

    fn alignmentOf(value: u8) std.mem.Alignment {
        const log2: std.math.Log2Int(usize) = @intCast(value);
        return @enumFromInt(log2);
    }

    /// Calls a `std.mem.Allocator` for the C functions.
    const Forward = struct {
        const vtable: VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

        fn sourceOf(context: *anyopaque) *const std.mem.Allocator {
            return @ptrCast(@alignCast(context));
        }

        fn alloc(context: *anyopaque, len: usize, alignment: u8, return_address: usize) callconv(.c) ?[*]u8 {
            const source = sourceOf(context);
            return source.rawAlloc(len, alignmentOf(alignment), return_address);
        }

        fn resize(context: *anyopaque, memory: [*]u8, len: usize, alignment: u8, new_len: usize, return_address: usize) callconv(.c) bool {
            const source = sourceOf(context);
            return source.rawResize(memory[0..len], alignmentOf(alignment), new_len, return_address);
        }

        fn remap(context: *anyopaque, memory: [*]u8, len: usize, alignment: u8, new_len: usize, return_address: usize) callconv(.c) ?[*]u8 {
            const source = sourceOf(context);
            return source.rawRemap(memory[0..len], alignmentOf(alignment), new_len, return_address);
        }

        fn free(context: *anyopaque, memory: [*]u8, len: usize, alignment: u8, return_address: usize) callconv(.c) void {
            const source = sourceOf(context);
            source.rawFree(memory[0..len], alignmentOf(alignment), return_address);
        }
    };

    /// Calls the C functions for a `std.mem.Allocator`.
    const Adapter = struct {
        const vtable: std.mem.Allocator.VTable = .{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

        fn sharedOf(context: *anyopaque) *const SharedAllocator {
            return @ptrCast(@alignCast(context));
        }

        fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
            const shared = sharedOf(context);
            return shared.vtable.alloc(shared.context, len, @intFromEnum(alignment), return_address);
        }

        fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) bool {
            const shared = sharedOf(context);
            return shared.vtable.resize(shared.context, memory.ptr, memory.len, @intFromEnum(alignment), new_len, return_address);
        }

        fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
            const shared = sharedOf(context);
            return shared.vtable.remap(shared.context, memory.ptr, memory.len, @intFromEnum(alignment), new_len, return_address);
        }

        fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
            const shared = sharedOf(context);
            shared.vtable.free(shared.context, memory.ptr, memory.len, @intFromEnum(alignment), return_address);
        }
    };
};

/// One incarnation of a resource lifetime scope. The record is bookkeeping owned by
/// `Memory.global`, so it stays at a stable address while the index grows and can
/// outlive the pages it releases. Every arena here allocates directly from `pages`:
/// releasing a dynamic arena returns its pages at once, while fixed storage is
/// reclaimed when the scope is released.
pub const Scope = struct {
    /// Reopening an Atom yields a new generation, so an old Id can never resolve to it.
    pub const Id = struct { atom: Atom, generation: u64 };
    /// Where a scope is in its life. `open` accepts work. `closing`, after
    /// `Memory.beginCloseScope`, creates no more arenas and still resolves by Id, so its owners can
    /// drain it. `abandoned` is a rollback or teardown that found direct backing outstanding. No
    /// owner is required to still hold the Id, so it is swept once the backing returns.
    pub const State = enum { open, closing, abandoned };
    /// What a scope holds, for reports.
    pub const Stats = struct {
        /// The pages charged to the scope, direct backing among them.
        backing: PageBacking.Stats,
        /// The usable capacity of its fixed and dynamic arenas together (`Arena.reserved`).
        arena_capacity_bytes: u64,
        /// The bytes those arenas handed out since each was last reset (`Arena.allocatedBytes`).
        handed_out_bytes: u64,
        /// How many dynamic arenas it has, labeled or not.
        dynamic_arena_count: usize,
    };
    /// A dynamic arena's record: a node of its scope's list, in `Memory.global` unless
    /// `outlives_admission`, when it lies in the arena's own pages.
    const DynamicArena = struct {
        arena: Arena,
        scope: *Scope,
        previous: ?*DynamicArena = null,
        next: ?*DynamicArena = null,
        admission_generation: u64,
        outlives_admission: bool = false,
        label: ?Atom = null,
        record: ?*Record = null,
    };
    /// Host state of one fixed layout that reloaded code finds by label instead of holding.
    /// Reserved and undefined until its owner publishes it and sets `installed`, so a prepared
    /// plan can stage the state and an abort leaves nothing behind.
    pub const Record = struct {
        /// The record's storage, in its labeled arena: at least the size asked of `labeledRecord`,
        /// aligned to 16 bytes, undefined until its owner writes it.
        bytes: []align(record_alignment) u8,
        /// Set by the owner once `bytes` holds state it has published.
        installed: bool = false,

        /// The record's bytes as a `T`, which must fit in them (asserted) and need no more than 16
        /// byte alignment (checked at compile time). `installed` is not checked.
        pub fn of(self: *const Record, comptime T: type) *T {
            comptime std.debug.assert(@alignOf(T) <= record_alignment);
            std.debug.assert(self.bytes.len >= @sizeOf(T));
            return @ptrCast(@alignCast(self.bytes.ptr));
        }
    };
    const record_alignment = 16;

    /// The Atom the scope was opened under, and which opening of it this is.
    id: Id,
    /// Logical parent for reporting memory as a tree; null for a root. Names the Atom
    /// rather than an incarnation and owns nothing: closing a parent does not close its
    /// children, so a released parent leaves the child orphaned until the Atom reopens.
    parent: ?Atom,
    /// Where the scope is in its life; see `State`.
    state: State = .open,
    /// Held by one owner through its `*Scope`. No Atom or Id resolves to it, so requests
    /// and table-driven lifecycles cannot place backing in it or close it.
    private: bool = false,
    /// The Memory the scope belongs to.
    memory: *Memory,
    /// The init admission the scope was opened in, 0 outside any: an abort of that admission
    /// destroys the scope.
    admission_generation: u64,
    /// Every page of this scope, including `direct`.
    pages: PageBacking,
    /// Backing handed straight to owners. Counted apart from arena pages so release can
    /// be refused before touching arenas that may hold those owners' bookkeeping.
    direct: PageBacking,
    /// Scope-lifetime storage, behind `fixedAllocator`.
    fixed: Arena,
    /// The scope's dynamic arenas, the latest created first.
    first_dynamic: ?*DynamicArena = null,

    /// Page backing for owners that manage their own pages, such as table storage.
    /// While any of it is outstanding the record and its arenas stay intact, so this
    /// allocator stays valid and the owner can still return it. See `releaseScope`.
    /// Direct backing is not attributed to an admission: keep its bookkeeping out of a
    /// dynamic arena created during one, because abort destroys that arena regardless.
    /// Resolves in the calling image, as every allocator Memory hands out does: an owner
    /// another image reaches keeps `direct` itself, not this.
    pub fn backingAllocator(self: *Scope) std.mem.Allocator {
        return self.direct.allocator();
    }

    /// Scope-lifetime records and immutable payloads. Allocations made during an init
    /// admission are not rolled back with it; they are reclaimed with the scope.
    pub fn fixedAllocator(self: *Scope) std.mem.Allocator {
        return self.fixed.allocator();
    }

    /// A dynamic arena of the scope's pages, the caller's until `releaseArena` or the scope's
    /// release. `error.ScopeClosing` unless the scope is open, and `error.OutOfMemory` when its
    /// record cannot be made. Created inside an init admission, an abort destroys it.
    pub fn createArena(self: *Scope) !*Arena {
        if (self.state != .open) return error.ScopeClosing;
        const global = self.memory.globalAllocator();
        const node = try global.create(DynamicArena);
        node.* = .{
            .arena = .{ .pages = &self.pages },
            .scope = self,
            .next = self.first_dynamic,
            .admission_generation = self.memory.activeAdmissionGeneration(),
        };
        if (self.first_dynamic) |first| first.previous = node;
        self.first_dynamic = node;
        _ = self.memory.admissionMutation(false);
        return &node.arena;
    }

    /// The arena of this name, created on first use, for owners that hold no pointer across a
    /// reload or an admission abort: an abort destroys one created inside it, and the next use
    /// creates it again. Fails as `createArena` does when it has to create.
    pub fn labeledArena(self: *Scope, label: Atom) !*Arena {
        if (self.findLabeled(label)) |node| return &node.arena;
        const arena = try self.createArena();
        const node: *DynamicArena = @alignCast(@fieldParentPtr("arena", arena));
        node.label = label;
        return arena;
    }

    /// The record of this label, reserved in its own labeled arena on first use with `size` bytes.
    /// An abort removes one reserved inside the admission along with that arena.
    /// `error.RecordTooSmall` when the record is there with fewer than `size` bytes; otherwise it
    /// fails as `labeledArena` does, or with `error.OutOfMemory`.
    pub fn labeledRecord(self: *Scope, label: Atom, size: usize) !*Record {
        const arena = try self.labeledArena(label);
        const node: *DynamicArena = @alignCast(@fieldParentPtr("arena", arena));
        // The caller may publish through it, so a validated admission must validate again.
        _ = self.memory.admissionMutation(false);
        if (node.record) |existing| {
            if (existing.bytes.len < size) return error.RecordTooSmall;
            return existing;
        }
        const allocator = arena.allocator();
        const bytes = try allocator.alignedAlloc(u8, .fromByteUnits(record_alignment), size);
        const created = try allocator.create(Record);
        created.* = .{ .bytes = bytes };
        node.record = created;
        return created;
    }

    /// Observation only: never creates the arena or its record.
    pub fn existingLabeledRecord(self: *const Scope, label: Atom) ?*Record {
        const node = self.findLabeled(label) orelse return null;
        return node.record;
    }

    /// Observation only: never creates the arena.
    pub fn existingLabeledArena(self: *const Scope, label: Atom) ?*Arena {
        const node = self.findLabeled(label) orelse return null;
        return &node.arena;
    }

    /// Observation only, for an admission snapshot: every record and its label.
    pub const RecordIterator = struct {
        /// The next arena to look at.
        node: ?*DynamicArena,

        /// The next record and its label, passing over arenas that have none; null at the end.
        pub fn next(self: *RecordIterator) ?struct { label: Atom, value: *Record } {
            while (self.node) |node| {
                self.node = node.next;
                const value = node.record orelse continue;
                return .{ .label = node.label.?, .value = value };
            }
            return null;
        }
    };

    /// Every labeled record of the scope. Creating or destroying an arena while iterating is not
    /// allowed.
    pub fn records(self: *const Scope) RecordIterator {
        return .{ .node = self.first_dynamic };
    }

    /// Refused like `releaseArena` when an admission protects it. Absent is not an error.
    pub fn releaseLabeled(self: *Scope, label: Atom) void {
        const node = self.findLabeled(label) orelse return;
        self.releaseArena(&node.arena);
    }

    /// Each labeled arena of the scope, with its label. Creating or destroying an arena
    /// while iterating is not allowed.
    pub fn labeledArenas(self: *const Scope) LabeledArenas {
        return .{ .node = self.first_dynamic };
    }

    /// The iterator `labeledArenas` returns.
    pub const LabeledArenas = struct {
        /// The next arena to look at.
        node: ?*DynamicArena,

        /// A labeled arena and its label.
        pub const Entry = struct { label: Atom, arena: *Arena };

        /// The next labeled arena, passing over unlabeled ones; null at the end.
        pub fn next(iterator: *LabeledArenas) ?Entry {
            while (iterator.node) |node| {
                iterator.node = node.next;
                const label = node.label orelse continue;
                return .{ .label = label, .arena = &node.arena };
            }
            return null;
        }
    };

    fn findLabeled(self: *const Scope, label: Atom) ?*DynamicArena {
        var it = self.first_dynamic;
        while (it) |node| : (it = node.next) {
            if (node.label == label) return node;
        }
        return null;
    }

    /// A dynamic arena outside admission accounting: an abort does not destroy it, and
    /// creating or releasing it neither rejects nor unvalidates the active admission.
    /// Only for monotonic state an admission never restores, which the admission snapshot must also
    /// exclude: the atom interner's maps. Its record lives inside its own pages, so its only
    /// allocation failure is its first page and `global` is untouched. `error.ScopeClosing` unless
    /// the scope is open.
    pub fn createAdmissionExemptArena(self: *Scope) !*Arena {
        if (self.state != .open) return error.ScopeClosing;
        var bootstrap: Arena = .{ .pages = &self.pages };
        const node = try bootstrap.allocator().create(DynamicArena);
        node.* = .{
            .arena = bootstrap,
            .scope = self,
            .next = self.first_dynamic,
            .admission_generation = 0,
            .outlives_admission = true,
        };
        if (self.first_dynamic) |first| first.previous = node;
        self.first_dynamic = node;
        return &node.arena;
    }

    /// Destroys an arena made by `createAdmissionExemptArena`, returning its pages. Asserts that it
    /// is this scope's and exempt.
    pub fn releaseAdmissionExemptArena(self: *Scope, arena: *Arena) void {
        const node: *DynamicArena = @alignCast(@fieldParentPtr("arena", arena));
        std.debug.assert(node.scope == self and node.outlives_admission);
        self.destroyDynamic(node);
    }

    /// Destroys an arena made by `createArena` or `labeledArena`, returning its pages at once: the
    /// pointer and everything allocated from the arena are invalid after. Inside an init admission
    /// an arena that predates it is protected: the call destroys nothing and rejects the admission,
    /// without a word (`Memory.rejectInsideAdmission` reports it).
    pub fn releaseArena(self: *Scope, arena: *Arena) void {
        const node: *DynamicArena = @alignCast(@fieldParentPtr("arena", arena));
        std.debug.assert(node.scope == self and !node.outlives_admission);
        const protected = self.memory.admission != null and node.admission_generation != self.memory.activeAdmissionGeneration();
        if (self.memory.admissionMutation(protected)) return;
        self.destroyDynamic(node);
    }

    fn destroyDynamic(self: *Scope, node: *DynamicArena) void {
        if (node.previous) |previous| previous.next = node.next else self.first_dynamic = node.next;
        if (node.next) |next| next.previous = node.previous;
        if (node.outlives_admission) {
            // The record is inside these pages: release through a copy that outlives them.
            var self_hosted = node.arena;
            self_hosted.deinit();
            return;
        }
        node.arena.deinit();
        const global = self.memory.globalAllocator();
        global.destroy(node);
    }

    /// Observation only: no allocation, reset or state change.
    pub fn stats(self: *const Scope) Stats {
        var result: Stats = .{
            .backing = self.pages.stats(),
            .arena_capacity_bytes = self.fixed.reserved(),
            .handed_out_bytes = self.fixed.allocatedBytes(),
            .dynamic_arena_count = 0,
        };
        var it = self.first_dynamic;
        while (it) |node| : (it = node.next) {
            result.arena_capacity_bytes += node.arena.reserved();
            result.handed_out_bytes += node.arena.allocatedBytes();
            result.dynamic_arena_count += 1;
        }
        return result;
    }

    /// Dynamic arenas go first, then fixed storage, then the record that owns the pages.
    /// False means direct backing is outstanding and nothing was changed: freeing either
    /// would strand the owner's allocator or the bookkeeping it needs to return the pages.
    fn tryDestroy(self: *Scope) bool {
        if (self.direct.stats().current_bytes != 0) return false;
        while (self.first_dynamic) |node| self.destroyDynamic(node);
        self.fixed.deinit();
        std.debug.assert(self.pages.stats().current_bytes == 0);
        const global = self.memory.globalAllocator();
        global.destroy(self);
        return true;
    }
};

/// The host's memory: its scopes, its scratch arenas and the report of both. Scope registry
/// mutation is main-thread-only. `deinit` must run after all subsystems
/// borrowing its scopes have deinitialized. Tables arenas are only observed: shutdown
/// detaches them without releasing their storage.
pub const Memory = struct {
    /// The name of the report table `syncTable` fills.
    pub const name = "memory";

    /// Holds the frame and table scratch arenas, page-backed so reports attribute them.
    pub const work_scope_name = "host.work";
    /// Parent of every private scope in reports. It owns nothing and has no record, since
    /// no lifetime ties host services together; the report gives it a row of its own.
    pub const host_root_name = "host";
    const host_root = Atom.from(host_root_name);
    /// Above this, a reset returns scratch pages. A frame that needs more every time pays
    /// for those pages every time; the shipped editor stays well under it.
    const scratch_retain_bytes = 16 * 1024 * 1024;
    // A sizing hint for the inspection table; the registry itself grows on demand.
    const initial_table_rows = 128;

    /// The `owner` names of the report's rows for the tables' own arenas, which hold the tables
    /// placed in no scope: persistent, durable, transient and singleton, in that order.
    pub const table_arena_owners = [_][]const u8{ "tables.persistent", "tables.durable", "tables.transient", "tables.singleton" };
    /// One table arena's reserved bytes and pages, as `Table.Registry.storageStats` gives them.
    pub const TableArenaStats = @FieldType(Table.Registry.StorageStats, "persistent");
    /// The token of an open init admission, from `beginInitAdmission`: the Memory it is of, and the
    /// admission's number. Tokens are tied to this immovable Memory instance; copied/stale tokens
    /// cannot finalize another admission. Validate ALL subsystems before any commit.
    pub const InitAdmission = struct { memory: *Memory, generation: u64 };
    const Admission = struct {
        generation: u64,
        scratch: ?*Arena,
        frame: ?*Arena,
        rejected: bool = false,
        validated: bool = false,
    };
    /// The open init admission, null outside one.
    admission: ?Admission = null,
    /// The number of the latest admission begun; never used twice.
    admission_generation: u64 = 0,

    /// The host's general-purpose allocator, called only through `global`'s functions, which
    /// `init` makes in the host.
    global_source: std.mem.Allocator,
    /// `global_source`, for the code of any image: `globalAllocator` adapts it where it is used.
    global: SharedAllocator,
    /// Where every scope's pages come from. A test refuses pages through it.
    page_source: PageSource = .{},
    /// Observed for reports only; its storage is not this Memory's to release.
    observed_tables: ?*const Table.Registry = null,

    /// Every scope record, open, closing or abandoned, in no order.
    scopes: std.ArrayList(*Scope) = .empty,
    /// The generation of the scope opened last; the next takes the one after.
    last_scope_generation: u64 = 0,

    /// The table scratch arena, made in the work scope on first use.
    scratch: ?*Arena = null,

    /// The frame scratch arena, made in the work scope on first use.
    frame: ?*Arena = null,

    /// Opens an init admission and returns its token: the bracket around a setup of several steps
    /// that must leave nothing behind when it fails, as opening a figure document's stores. The
    /// caller does the work, calls `validateInitAdmission` last, then `commitInitAdmission`; on any
    /// error it calls `abortInitAdmission`. `error.AdmissionAlreadyActive` when one is open: they
    /// do not nest. `error.AdmissionGenerationExhausted` after 2^64 of them.
    pub fn beginInitAdmission(self: *Memory) !InitAdmission {
        if (self.admission != null) return error.AdmissionAlreadyActive;
        self.admission_generation = std.math.add(u64, self.admission_generation, 1) catch return error.AdmissionGenerationExhausted;
        self.sweepAbandonedScopes();
        self.admission = .{ .generation = self.admission_generation, .scratch = self.scratch, .frame = self.frame };
        return .{ .memory = self, .generation = self.admission_generation };
    }

    fn validToken(self: *Memory, token: InitAdmission) bool {
        return token.memory == self and self.admission != null and self.admission.?.generation == token.generation;
    }

    /// Marks the admission ready to commit. `error.InvalidAdmissionToken` for a token that is not
    /// the open admission's, and `error.AdmissionMutationRejected` when a protected change was
    /// refused during it, which leaves abort as the only end. Anything the admission tracks after
    /// this (a scope opened, an arena created, table scratch taken) withdraws the mark, so validate
    /// last.
    pub fn validateInitAdmission(self: *Memory, token: InitAdmission) !void {
        if (!self.validToken(token)) return error.InvalidAdmissionToken;
        if (self.admission.?.rejected) return error.AdmissionMutationRejected;
        self.admission.?.validated = true;
    }

    /// Nonfallible publication. False means invalid/unvalidated token; nothing changed.
    /// No admission operations may occur between final validation and publication.
    pub fn commitInitAdmission(self: *Memory, token: InitAdmission) bool {
        if (!self.validToken(token) or !self.admission.?.validated) return false;
        self.admission = null;
        return true;
    }

    /// Rolls the admission back: destroys every scope opened in it and every dynamic arena created
    /// in it in an older scope, admission-exempt arenas aside, and puts the scratch arenas back as
    /// they were. A scope of it with direct backing outstanding is abandoned instead, and swept
    /// once the backing returns. What an older scope's fixed arena allocated during the admission
    /// stays. False, with nothing changed, for a token that is not the open admission's.
    pub fn abortInitAdmission(self: *Memory, token: InitAdmission) bool {
        if (!self.validToken(token)) return false;
        const a = self.admission.?;
        var scope_index: usize = 0;
        while (scope_index < self.scopes.items.len) {
            const scope = self.scopes.items[scope_index];
            if (scope.admission_generation == a.generation) {
                if (scope.tryDestroy()) {
                    _ = self.scopes.swapRemove(scope_index);
                } else {
                    scope.state = .abandoned;
                    scope_index += 1;
                }
                continue;
            }
            var it = scope.first_dynamic;
            while (it) |node| {
                it = node.next;
                if (!node.outlives_admission and node.admission_generation == a.generation) scope.destroyDynamic(node);
            }
            scope_index += 1;
        }
        self.scratch = a.scratch;
        self.frame = a.frame;
        self.admission = null;
        return true;
    }

    fn activeAdmissionGeneration(self: *const Memory) u64 {
        const a = self.admission orelse return 0;
        return a.generation;
    }

    /// For an owner about to publish state that must not exist if the active admission
    /// aborts, or to release what it protects. Refuses and rejects it, as any protected
    /// mutation does. Call before the first change; `Scope.releaseArena` only refuses silently.
    pub fn rejectInsideAdmission(self: *Memory) !void {
        if (self.admissionMutation(self.admission != null)) return error.AdmissionMutationRejected;
    }

    fn admissionMutation(self: *Memory, protected: bool) bool {
        if (self.admission) |*a| {
            a.validated = false;
            if (protected) a.rejected = true;
        }
        return self.admission != null and protected;
    }

    /// Initializes `self` in place, with no scopes. `self` must not move afterwards: its scopes and
    /// `global` point into it. `global` is the host's general-purpose allocator, which holds the
    /// bookkeeping and must outlive `self`. The host calls it, so `global`'s functions are the
    /// host's.
    pub fn init(self: *Memory, global: std.mem.Allocator) void {
        self.* = .{ .global_source = global, .global = undefined };
        self.global = SharedAllocator.wrap(&self.global_source);
    }

    /// For use there and then: an allocator kept where another image may call it must be the
    /// `SharedAllocator` itself.
    pub fn globalAllocator(self: *const Memory) std.mem.Allocator {
        return self.global.allocator();
    }

    /// Aborts an open admission, forgets the scratch arenas and the observed tables, and destroys
    /// every scope whose direct backing has been returned. A scope with backing outstanding is
    /// logged, abandoned and kept, so its owner can still return it; a second `deinit` after that
    /// finishes the release.
    pub fn deinit(self: *Memory) void {
        if (self.admission) |a| _ = self.abortInitAdmission(.{ .memory = self, .generation = a.generation });
        self.observed_tables = null;
        self.scratch = null;
        self.frame = null;
        // A scope with outstanding backing survives so a later owner teardown can return
        // it; calling deinit again after that teardown finishes the release.
        var scope_index: usize = 0;
        while (scope_index < self.scopes.items.len) {
            const scope = self.scopes.items[scope_index];
            if (scope.tryDestroy()) {
                _ = self.scopes.swapRemove(scope_index);
            } else {
                std.log.warn("memory scope still has direct backing at teardown", .{});
                scope.state = .abandoned;
                scope_index += 1;
            }
        }
        if (self.scopes.items.len == 0) {
            self.scopes.deinit(self.globalAllocator());
            self.scopes = .empty;
        }
    }

    fn sweepAbandonedScopes(self: *Memory) void {
        var scope_index: usize = 0;
        while (scope_index < self.scopes.items.len) {
            const scope = self.scopes.items[scope_index];
            if (scope.state == .abandoned and scope.tryDestroy()) {
                _ = self.scopes.swapRemove(scope_index);
            } else {
                scope_index += 1;
            }
        }
    }

    fn findScope(self: *const Memory, atom: Atom) ?*Scope {
        for (self.scopes.items) |scope| {
            if (scope.id.atom == atom) return scope;
        }
        return null;
    }

    /// Opens a root scope under `atom` and returns its Id: the lifecycle owner opens a scope
    /// explicitly, and ends it with `beginCloseScope` and `releaseScope`. A closing Atom cannot be
    /// reopened until it is released. Opened during an admission, the scope aborts with it.
    /// `error.InvalidScope` for the zero Atom, `error.ScopeAlreadyOpen` while the Atom's scope is
    /// open, `error.ScopeClosing` while it is closing or abandoned, `error.OutOfMemory`, and
    /// `error.ScopeGenerationExhausted` after 2^64 scopes.
    pub fn openScope(self: *Memory, atom: Atom) !Scope.Id {
        return self.openScopeRecord(atom, null);
    }

    /// Opens a scope its one owner holds by pointer, for host state whose owner outlives every
    /// other user of Memory's scopes, such as the interner and the log. It appears in reports but
    /// not to `resolveScope` or `scopeFor`, and its Atom stays taken. The owner ends it with
    /// `releasePrivateScope`. Refused inside an admission (`error.AdmissionActive`): an abort would
    /// destroy the scope under a pointer no Id can show as stale. Otherwise it fails as `openScope`
    /// does.
    pub fn openPrivateScope(self: *Memory, atom: Atom) !*Scope {
        if (self.admission != null) return error.AdmissionActive;
        const id = try self.openScopeRecord(atom, host_root);
        const scope = self.findScope(id.atom).?;
        scope.private = true;
        return scope;
    }

    /// One private scope for every owner of a kind, such as each holder of resources' reply arenas:
    /// opened by the first to ask and found by the rest. Each owner returns what it took, and the
    /// scope ends with Memory. `error.ScopeAlreadyOpen` when `atom` names a scope that is not an
    /// open private one; otherwise it fails as `openPrivateScope` does.
    pub fn sharedPrivateScope(self: *Memory, atom: Atom) !*Scope {
        if (self.findScope(atom)) |existing| {
            if (existing.private and existing.state == .open) return existing;
            return error.ScopeAlreadyOpen;
        }
        return self.openPrivateScope(atom);
    }

    /// False inside an admission, which cannot restore it, and while direct backing is
    /// outstanding; `Memory.deinit` then reclaims the scope. The scope is unusable
    /// after true.
    pub fn releasePrivateScope(self: *Memory, scope: *Scope) bool {
        std.debug.assert(scope.private);
        if (self.admission != null) return false;
        const index = std.mem.indexOfScalar(*Scope, self.scopes.items, scope).?;
        if (!scope.tryDestroy()) return false;
        _ = self.scopes.swapRemove(index);
        return true;
    }

    /// A scope reported beneath `parent`, which must be open (`error.ParentScopeNotOpen`): a
    /// closing lifetime accepts no new work, including children. See `Scope.parent` for what the
    /// link does not do. Otherwise as `openScope`.
    pub fn openChildScope(self: *Memory, atom: Atom, parent: Atom) !Scope.Id {
        if (self.resolveScope(parent) == null) return error.ParentScopeNotOpen;
        return self.openScopeRecord(atom, parent);
    }

    fn openScopeRecord(self: *Memory, atom: Atom, parent: ?Atom) !Scope.Id {
        if (@intFromEnum(atom) == 0) return error.InvalidScope;
        self.sweepAbandonedScopes();
        if (self.findScope(atom)) |existing| {
            return switch (existing.state) {
                .open => error.ScopeAlreadyOpen,
                .closing, .abandoned => error.ScopeClosing,
            };
        }
        const generation = std.math.add(u64, self.last_scope_generation, 1) catch return error.ScopeGenerationExhausted;
        const global = self.globalAllocator();
        try self.scopes.ensureUnusedCapacity(global, 1);
        const scope = try global.create(Scope);
        scope.* = .{
            .id = .{ .atom = atom, .generation = generation },
            .parent = parent,
            .memory = self,
            .admission_generation = self.activeAdmissionGeneration(),
            .pages = .{ .upstream = .{ .source = &self.page_source } },
            .direct = undefined,
            .fixed = undefined,
        };
        scope.direct = .{ .upstream = .{ .parent = &scope.pages } };
        scope.fixed = .{ .pages = &scope.pages };
        self.scopes.appendAssumeCapacity(scope);
        self.last_scope_generation = generation;
        _ = self.admissionMutation(false);
        return scope.id;
    }

    /// The current incarnation accepting new work. Resolve when accepting work and
    /// carry the Id through deferred dispatch rather than resolving the Atom again.
    pub fn resolveScope(self: *const Memory, atom: Atom) ?Scope.Id {
        const scope = self.findScope(atom) orelse return null;
        if (scope.state != .open or scope.private) return null;
        return scope.id;
    }

    /// Null for a stale Id. A closing scope still resolves so its owners can drain it.
    pub fn scopeFor(self: *const Memory, id: Scope.Id) ?*Scope {
        const found = self.findScope(id.atom) orelse return null;
        if (found.id.generation != id.generation or found.private) return null;
        return found;
    }

    /// Stops the scope accepting work: `resolveScope` no longer finds it and it creates no more
    /// arenas. Owners then drain and release their borrows before `releaseScope`. A repeated close
    /// reports `error.ScopeClosing` rather than destroying twice; `error.StaleScope` for an Id that
    /// is not a scope's, and `error.AdmissionMutationRejected` inside an init admission the scope
    /// predates.
    pub fn beginCloseScope(self: *Memory, id: Scope.Id) !void {
        const found = self.scopeFor(id) orelse return error.StaleScope;
        if (found.state != .open) return error.ScopeClosing;
        if (self.scopeMutationRejected(found)) return error.AdmissionMutationRejected;
        found.state = .closing;
    }

    /// Destroys a closing scope: its arenas, its fixed storage and its record, every page returned.
    /// `error.ScopeNotClosing` before `beginCloseScope`. `error.ScopeBackingOutstanding` means an
    /// owner has not returned direct backing. Nothing is released; the scope keeps its state and
    /// this call can be repeated. `error.StaleScope` on a repeat means the record was abandoned and
    /// has since been swept: the release is done. `error.AdmissionMutationRejected` inside an init
    /// admission the scope predates.
    pub fn releaseScope(self: *Memory, id: Scope.Id) !void {
        const found = self.scopeFor(id) orelse return error.StaleScope;
        if (found.state == .open) return error.ScopeNotClosing;
        if (self.scopeMutationRejected(found)) return error.AdmissionMutationRejected;
        const index = std.mem.indexOfScalar(*Scope, self.scopes.items, found).?;
        if (!found.tryDestroy()) return error.ScopeBackingOutstanding;
        _ = self.scopes.swapRemove(index);
    }

    fn scopeMutationRejected(self: *Memory, found: *const Scope) bool {
        // Abandoned records are not part of any state an admission could restore.
        const preexisting = found.admission_generation != self.activeAdmissionGeneration();
        const protected = self.admission != null and preexisting and found.state != .abandoned;
        return self.admissionMutation(protected);
    }

    /// Has the report include `tables`' own arenas: observes the immovable host-owned registry,
    /// with no allocator access or retained callbacks. `error.AlreadyRegistered` for the registry
    /// already observed, `error.ReservedOwner` while another is, and
    /// `error.AdmissionMutationRejected` inside an init admission, which it rejects.
    pub fn registerTables(self: *Memory, tables: *const Table.Registry) !void {
        if (self.admissionMutation(self.admission != null)) return error.AdmissionMutationRejected;
        if (self.observed_tables) |observed| {
            return if (observed == tables) error.AlreadyRegistered else error.ReservedOwner;
        }
        self.observed_tables = tables;
    }

    /// Stops observing `tables`, if it is the registry observed. Identity-based detach must precede
    /// the registry's storage destruction. Idempotent, and safe after `Memory.deinit` while the
    /// host-owned Memory object itself still exists. Inside an init admission it does nothing but
    /// reject the admission.
    pub fn unregisterTables(self: *Memory, tables: *const Table.Registry) void {
        if (self.admissionMutation(self.admission != null)) return;
        if (self.observed_tables == tables) self.observed_tables = null;
    }

    /// The stats of the table arena reported as `owner`, one of `table_arena_owners`; null for any
    /// other name, or with no tables registered. The singleton arena's `reserved_pages` is 0,
    /// meaning not measured.
    pub fn tableArenaStats(self: *const Memory, owner: []const u8) ?TableArenaStats {
        const tables = self.observed_tables orelse return null;
        for (table_arena_owners, 0..) |reserved, index| {
            if (std.mem.eql(u8, reserved, owner)) return tableArenaRow(tables, index);
        }
        return null;
    }

    fn tableArenaRow(tables: *const Table.Registry, index: usize) TableArenaStats {
        const stats = tables.storageStats();
        return switch (index) {
            0 => stats.persistent,
            1 => stats.durable,
            2 => stats.transient,
            // `Arena.reserved` is usable capacity, not a count of mapped pages.
            // Zero pages means unavailable here; syncTable omits the cell.
            3 => .{ .reserved_bytes = stats.singleton_bytes, .reserved_pages = 0 },
            else => unreachable,
        };
    }

    /// A private scope that callers look up each time instead of holding. Opened like any scope
    /// inside an admission, so an abort destroys it along with its arenas, and no pointer to
    /// it survives. Named only by its owner, so no request or table can close it.
    pub fn resolvedPrivateScope(self: *Memory, atom: Atom) !*Scope {
        if (self.findScope(atom)) |scope| {
            if (scope.private and scope.state == .open) return scope;
            return error.ScopeAlreadyOpen;
        }
        const id = try self.openScopeRecord(atom, host_root);
        const scope = self.findScope(id.atom).?;
        scope.private = true;
        return scope;
    }

    /// Observation only: `resolvedPrivateScope` without opening it.
    pub fn existingPrivateScope(self: *const Memory, atom: Atom) ?*Scope {
        const scope = self.findScope(atom) orelse return null;
        return if (scope.private and scope.state == .open) scope else null;
    }

    fn workScope(self: *Memory) !*Scope {
        return self.resolvedPrivateScope(Atom.from(work_scope_name));
    }

    fn scratchAllocator(arena: *Arena) Scratch {
        return .{ .allocator = arena.allocator() };
    }

    /// Scratch for building what a table call consumes at once, such as a schema: each call empties
    /// it first. Returned storage is invalidated by the next call; use only on the main thread and
    /// do not re-enter before consuming the returned data. Inside an init admission the arena that
    /// predates it is not emptied, so an abort finds it as it was. Fails only when the work scope
    /// or its arena cannot be made.
    pub fn tableScratchAllocator(self: *Memory) !Scratch {
        if (self.scratch == null) {
            const scope = try self.workScope();
            self.scratch = try scope.createArena();
        }
        _ = self.admissionMutation(false);
        if (self.admission == null or self.scratch != self.admission.?.scratch) {
            _ = self.scratch.?.reset(.{ .retain_with_limit = scratch_retain_bytes });
        }
        return scratchAllocator(self.scratch.?);
    }

    /// Ends the frame's scratch: everything allocated from it is invalid after. The host calls it
    /// after each pump that has no later consumer of it; a message or command left for the next
    /// pump must not point here. Inside an init admission that the frame arena predates it does
    /// nothing but reject the admission.
    pub fn beginFrame(self: *Memory) void {
        if (self.admissionMutation(self.admission != null and self.frame != null and self.frame == self.admission.?.frame)) return;
        if (self.frame) |f| _ = f.reset(.{ .retain_with_limit = scratch_retain_bytes });
    }

    /// The frame's scratch arena, for an owner that keeps the arena rather than an allocator.
    /// Allocations remain valid only until the next `beginFrame()`.
    pub fn frameScratchArena(self: *Memory) !*Arena {
        if (self.frame == null) {
            const scope = try self.workScope();
            self.frame = try scope.createArena();
        }
        return self.frame.?;
    }

    /// The frame's scratch, for temporaries of the frame: never freed piece by piece.
    /// Allocations remain valid only until the next `beginFrame()`. Fails only when the work
    /// scope or its arena cannot be made.
    pub fn frameScratchAllocator(self: *Memory) !Scratch {
        const arena = try self.frameScratchArena();
        return scratchAllocator(arena);
    }

    const report_fields = 9;

    /// Fills the report table `memory` (`Memory.name`), made durable on first use: its rows are
    /// replaced each call. It takes the table scratch, so storage from an earlier
    /// `tableScratchAllocator` is invalid after. One row per scope and per unscoped table arena.
    /// `parent` is empty for a root; with
    /// `owner` it gives the tree. `capacity` and `allocated` are arena capacity and bytes
    /// handed out, `backing_bytes` the page-rounded charge and `peak_bytes` its high mark.
    /// Every scope backing byte is reported once, on its scope's row. Pages of scoped tables
    /// are in that scope and not in `Table.Registry.storageStats`, whose rows cover unscoped tables
    /// and the singleton arena, so `backing_bytes` and `tables.*` never overlap.
    pub fn syncTable(self: *Memory, tables: *Table.Registry, atoms: *Atom.Registry) !void {
        const scratch = try self.tableScratchAllocator();
        var schema: Table.Schema = undefined;
        try schema.init(scratch.allocator, atoms, report_fields);
        defer schema.deinit();
        schema.addField("owner", Atom, .atom);
        schema.addField("kind", Atom, .atom);
        schema.addField("parent", Atom, .atom);
        schema.addField("capacity", u64, .int);
        schema.addField("allocated", u64, .int);
        schema.addField("reserved_pages", u64, .int);
        schema.addField("backing_bytes", u64, .int);
        schema.addField("peak_bytes", u64, .int);
        schema.addField("dynamic_arenas", u64, .int);
        const ensured = try tables.ensure(&schema, initial_table_rows, atoms.intern(name), .durable);
        const t = ensured.table;
        const table_row_count: usize = if (self.observed_tables != null) table_arena_owners.len else 0;
        // One more for the `host` root, a row with no record of its own.
        const required_rows = std.math.cast(u32, table_row_count + self.scopes.items.len + 1) orelse return error.Overflow;
        // Rows would grow on demand, but `insert` treats allocation failure as fatal.
        if (t.rowCapacity() < required_rows) try tables.grow(ensured.handle, required_rows);
        t.clear();
        if (self.observed_tables) |observed| {
            const kind = atoms.intern("table_arena");
            for (table_arena_owners, 0..) |owner, index| {
                const stats = tableArenaRow(observed, index);
                const row = t.insert(.{
                    .owner = atoms.intern(owner),
                    .kind = kind,
                    .capacity = @as(u64, stats.reserved_bytes),
                    .allocated = @as(u64, stats.reserved_bytes),
                });
                // The singleton arena has no page count; zero would read as a measurement.
                if (index != 3) {
                    t.writeFieldSingle(u64, row, "reserved_pages", stats.reserved_pages) catch unreachable;
                    t.writeFieldSingle(u64, row, "backing_bytes", stats.reserved_pages * std.heap.pageSize()) catch unreachable;
                }
            }
        }
        // The owner is the scope's Atom, which reads as a name only if its opener interned it.
        const scope_kind = atoms.intern("scope");
        const host_root_name_atom = atoms.intern(host_root_name);
        var any_private = false;
        for (self.scopes.items) |scope| {
            any_private = any_private or scope.private;
            const stats = scope.stats();
            const row = t.insert(.{
                .owner = scope.id.atom,
                .kind = scope_kind,
                .capacity = stats.arena_capacity_bytes,
                .allocated = stats.handed_out_bytes,
                .reserved_pages = stats.backing.current_bytes / std.heap.pageSize(),
                .backing_bytes = stats.backing.current_bytes,
                .peak_bytes = stats.backing.peak_bytes,
                .dynamic_arenas = @as(u64, stats.dynamic_arena_count),
            });
            if (scope.parent) |parent| t.writeFieldSingle(Atom, row, "parent", parent) catch unreachable;
        }
        if (any_private) {
            const zero: u64 = 0;
            _ = t.insert(.{
                .owner = host_root_name_atom,
                .kind = scope_kind,
                .capacity = zero,
                .allocated = zero,
                .reserved_pages = zero,
                .backing_bytes = zero,
                .peak_bytes = zero,
                .dynamic_arenas = zero,
            });
        }
    }
};

/// A bump arena over a scope's pages, for one thread at a time. It calls its PageBacking
/// directly and holds no allocator, so the code of either image may use it; `allocator()`
/// resolves in the calling image.
pub const Arena = struct {
    /// The backing its chunks come from and return to, which must outlive the arena.
    pages: *PageBacking,
    /// Chunks in use, the newest first: allocation bumps in the first.
    used: ?*Chunk = null,
    /// Chunks a reset kept, which allocation takes before mapping more.
    spare: ?*Chunk = null,
    /// Bytes handed out since the last reset; see `allocatedBytes`.
    handed_out: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),

    /// What `reset` keeps, as `std.heap.ArenaAllocator` names it: `free_all`, `retain_capacity`, or
    /// `retain_with_limit` with a number of bytes of capacity.
    pub const ResetMode = std.heap.ArenaAllocator.ResetMode;

    /// A chunk's header, at the start of its pages; its bytes follow it.
    const Chunk = struct {
        /// The next chunk of the list it is in, `used` or `spare`.
        next: ?*Chunk,
        /// Bytes mapped, the header's among them.
        mapped: usize,
        /// The mapping's alignment, which freeing it repeats.
        alignment: std.mem.Alignment,
        /// Offset from the chunk's address of its first free byte.
        end: usize,

        fn base(chunk: *Chunk) [*]u8 {
            return @ptrCast(chunk);
        }

        fn capacity(chunk: *const Chunk) usize {
            return chunk.mapped - header_bytes;
        }

        /// Where `len` bytes aligned to `alignment` would start in the chunk, if they fit.
        fn fit(chunk: *Chunk, len: usize, alignment: std.mem.Alignment) ?usize {
            const base_address = @intFromPtr(chunk);
            const free_address = base_address + chunk.end;
            const start = alignment.forward(free_address) - base_address;
            const end = std.math.add(usize, start, len) catch return null;
            if (end > chunk.mapped) return null;
            return start;
        }

        /// Whether `memory` is the chunk's newest allocation.
        fn endsAtFree(chunk: *Chunk, memory: []u8) bool {
            const memory_end = @intFromPtr(memory.ptr) + memory.len;
            return memory_end == @intFromPtr(chunk) + chunk.end;
        }
    };
    const header_bytes = std.mem.alignForward(usize, @sizeOf(Chunk), 16);

    /// The `std.mem.Allocator` functions over an arena, in the image this code is compiled into;
    /// `allocator` uses it.
    pub const vtable: std.mem.Allocator.VTable = .{
        .alloc = trAlloc,
        .resize = trResize,
        .remap = trRemap,
        .free = trFree,
    };

    /// Resolves in the calling image: for use there and then, never to be kept where another
    /// image may call it.
    pub fn allocator(self: *Arena) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// Usable arena capacity, not mapped bytes (chunk headers are excluded).
    pub fn reserved(self: *const Arena) usize {
        return capacityOf(self.used) + capacityOf(self.spare);
    }

    fn capacityOf(first: ?*Chunk) usize {
        var total: usize = 0;
        var it = first;
        while (it) |chunk| : (it = chunk.next) total += chunk.capacity();
        return total;
    }

    /// Handed-out bytes since reset, not a live-payload measurement.
    pub fn allocatedBytes(self: *const Arena) usize {
        return self.handed_out.load(.monotonic);
    }

    /// Empties the arena: everything allocated from it is invalid after. Every chunk becomes spare,
    /// and those past the mode's limit of capacity return their pages, the newest kept first. Never
    /// fails: it always returns true.
    pub fn reset(self: *Arena, mode: ResetMode) bool {
        const limit: usize = switch (mode) {
            .free_all => 0,
            .retain_capacity => std.math.maxInt(usize),
            .retain_with_limit => |bytes| bytes,
        };
        // The used chunks, newest first, then the spare ones: kept in that order to the limit.
        var chunks = self.used orelse self.spare;
        if (self.used) |first| {
            var last = first;
            while (last.next) |next| last = next;
            last.next = self.spare;
        }
        self.used = null;
        self.spare = null;
        var kept_bytes: usize = 0;
        var kept_last: ?*Chunk = null;
        while (chunks) |chunk| {
            chunks = chunk.next;
            const within_limit = kept_bytes + chunk.capacity() <= limit;
            if (!within_limit) {
                self.release(chunk);
                continue;
            }
            kept_bytes += chunk.capacity();
            chunk.end = header_bytes;
            chunk.next = null;
            if (kept_last) |last| last.next = chunk else self.spare = chunk;
            kept_last = chunk;
        }
        self.handed_out.store(0, .monotonic);
        return true;
    }

    /// Returns every page to the backing. The arena is left empty and may be used again.
    pub fn deinit(self: *Arena) void {
        _ = self.reset(.free_all);
    }

    fn release(self: *Arena, chunk: *Chunk) void {
        const memory = chunk.base()[0..chunk.mapped];
        self.pages.rawFree(memory, chunk.alignment, @returnAddress());
    }

    /// A spare chunk `len` bytes fit in, taken off the spare list.
    fn takeSpare(self: *Arena, len: usize, alignment: std.mem.Alignment) ?*Chunk {
        var previous: ?*Chunk = null;
        var it = self.spare;
        while (it) |chunk| : (it = chunk.next) {
            if (chunk.fit(len, alignment) != null) {
                if (previous) |before| before.next = chunk.next else self.spare = chunk.next;
                return chunk;
            }
            previous = chunk;
        }
        return null;
    }

    /// Pages for a chunk `len` bytes fit in, half again as large as the newest one or more.
    fn mapChunk(self: *Arena, len: usize, alignment: std.mem.Alignment) ?*Chunk {
        const page_size = std.heap.pageSize();
        const chunk_alignment = alignment.max(.fromByteUnits(page_size));
        const data_offset = alignment.forward(header_bytes);
        const needed = std.math.add(usize, data_offset, len) catch return null;
        const newest: usize = if (self.used) |chunk| chunk.mapped else 0;
        const grown = newest + newest / 2;
        const wanted = @max(needed, grown);
        const padded = std.math.add(usize, wanted, page_size - 1) catch return null;
        const mapped = std.mem.alignBackward(usize, padded, page_size);
        const raw = self.pages.rawAlloc(mapped, chunk_alignment, @returnAddress()) orelse return null;
        const chunk: *Chunk = @ptrCast(@alignCast(raw));
        chunk.* = .{ .next = null, .mapped = mapped, .alignment = chunk_alignment, .end = header_bytes };
        return chunk;
    }

    /// `len` bytes at `alignment`, their contents undefined: from the newest chunk, else a spare
    /// one that fits, else newly mapped pages. Null when the backing refuses the pages.
    pub fn rawAlloc(self: *Arena, len: usize, alignment: std.mem.Alignment) ?[*]u8 {
        if (self.used) |current| {
            if (current.fit(len, alignment)) |start| return self.handOut(current, start, len);
        }
        const chunk = self.takeSpare(len, alignment) orelse self.mapChunk(len, alignment) orelse return null;
        chunk.next = self.used;
        self.used = chunk;
        const start = chunk.fit(len, alignment).?;
        return self.handOut(chunk, start, len);
    }

    fn handOut(self: *Arena, chunk: *Chunk, start: usize, len: usize) [*]u8 {
        chunk.end = start + len;
        _ = self.handed_out.fetchAdd(len, .monotonic);
        return chunk.base() + start;
    }

    /// Resizes `memory`, an allocation of this arena, in place. Grows only the newest allocation,
    /// within its chunk; shrinks any. False, with nothing changed, when it cannot.
    pub fn rawResize(self: *Arena, memory: []u8, new_len: usize) bool {
        const old_len = memory.len;
        const current = self.used orelse return new_len <= old_len;
        if (current.endsAtFree(memory)) {
            const start = @intFromPtr(memory.ptr) - @intFromPtr(current);
            const new_end = std.math.add(usize, start, new_len) catch return false;
            if (new_end > current.mapped) return false;
            current.end = new_end;
        } else if (new_len > old_len) {
            return false;
        }
        if (new_len >= old_len) {
            _ = self.handed_out.fetchAdd(new_len - old_len, .monotonic);
        } else {
            _ = self.handed_out.fetchSub(old_len - new_len, .monotonic);
        }
        return true;
    }

    /// Frees `memory`, an allocation of this arena. Takes back only the newest allocation's bytes:
    /// any other stays held until `reset`.
    pub fn rawFree(self: *Arena, memory: []u8) void {
        const current = self.used orelse return;
        if (!current.endsAtFree(memory)) return;
        current.end = @intFromPtr(memory.ptr) - @intFromPtr(current);
    }

    fn trAlloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, return_address: usize) ?[*]u8 {
        _ = return_address;
        const self: *Arena = @ptrCast(@alignCast(context));
        return self.rawAlloc(len, alignment);
    }

    fn trResize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) bool {
        _ = alignment;
        _ = return_address;
        const self: *Arena = @ptrCast(@alignCast(context));
        return self.rawResize(memory, new_len);
    }

    fn trRemap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, return_address: usize) ?[*]u8 {
        if (trResize(context, memory, alignment, new_len, return_address)) return memory.ptr;
        return null;
    }

    fn trFree(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, return_address: usize) void {
        _ = alignment;
        _ = return_address;
        const self: *Arena = @ptrCast(@alignCast(context));
        self.rawFree(memory);
    }
};

const testing = std.testing;

test "PageBacking accounts page-rounded allocation, resize and free" {
    const page_size = std.heap.pageSize();
    var source: PageSource = .{};
    var pages: PageBacking = .{ .upstream = .{ .source = &source } };
    const allocator = pages.allocator();

    var bytes = try allocator.alloc(u8, 1);
    try testing.expectEqual(PageBacking.Stats{ .current_bytes = page_size, .peak_bytes = page_size }, pages.stats());

    // Growth inside the rounded page changes nothing.
    try testing.expect(allocator.resize(bytes, page_size));
    bytes.len = page_size;
    try testing.expectEqual(@as(u64, page_size), pages.stats().current_bytes);

    // Targets that cannot remap in place copy, briefly holding both allocations.
    bytes = try allocator.realloc(bytes, 4 * page_size);
    const grown = pages.stats();
    try testing.expectEqual(@as(u64, 4 * page_size), grown.current_bytes);
    try testing.expect(grown.peak_bytes >= 4 * page_size);

    try testing.expect(allocator.resize(bytes, 3 * page_size));
    bytes.len = 3 * page_size;
    try testing.expectEqual(PageBacking.Stats{ .current_bytes = 3 * page_size, .peak_bytes = grown.peak_bytes }, pages.stats());

    bytes = try allocator.realloc(bytes, 2 * page_size);
    try testing.expectEqual(PageBacking.Stats{ .current_bytes = 2 * page_size, .peak_bytes = grown.peak_bytes }, pages.stats());

    allocator.free(bytes);
    try testing.expectEqual(PageBacking.Stats{ .current_bytes = 0, .peak_bytes = grown.peak_bytes }, pages.stats());
}

test "PageBacking charges its parent for what it takes" {
    const page_size = std.heap.pageSize();
    var source: PageSource = .{};
    var pages: PageBacking = .{ .upstream = .{ .source = &source } };
    var direct: PageBacking = .{ .upstream = .{ .parent = &pages } };
    const bytes = direct.rawAlloc(1, .of(u8), @returnAddress()).?;
    try testing.expectEqual(@as(u64, page_size), direct.stats().current_bytes);
    try testing.expectEqual(@as(u64, page_size), pages.stats().current_bytes);
    direct.rawFree(bytes[0..1], .of(u8), @returnAddress());
    try testing.expectEqual(@as(u64, 0), pages.stats().current_bytes);
    try testing.expectEqual(@as(usize, 1), source.deallocations.load(.monotonic));
}

test "PageBacking rejects unrepresentable lengths before reaching its source" {
    var source: PageSource = .{};
    source.refuseAfter(0);
    source.refuseResizesAfter(0);
    var pages: PageBacking = .{ .upstream = .{ .source = &source } };
    const allocator = pages.allocator();
    const byte_alignment = std.mem.Alignment.of(u8);
    const unrepresentable = std.math.maxInt(usize);
    var live: [1]u8 = undefined;

    try testing.expectEqual(@as(?[*]u8, null), allocator.rawAlloc(unrepresentable, byte_alignment, @returnAddress()));
    try testing.expect(!allocator.rawResize(&live, byte_alignment, unrepresentable, @returnAddress()));
    try testing.expectEqual(@as(?[*]u8, null), allocator.rawRemap(&live, byte_alignment, unrepresentable, @returnAddress()));
    try testing.expect(!source.has_induced_failure.load(.monotonic));
}

test "PageBacking honors over-page alignment" {
    const page_size = std.heap.pageSize();
    var source: PageSource = .{};
    var pages: PageBacking = .{ .upstream = .{ .source = &source } };
    const allocator = pages.allocator();
    const alignment = std.mem.Alignment.fromByteUnits(4 * page_size);

    // A real mapping can land aligned by chance, so take several.
    var taken: [8][*]u8 = undefined;
    for (&taken) |*bytes| {
        bytes.* = allocator.rawAlloc(1, alignment, @returnAddress()) orelse return error.OutOfMemory;
        try testing.expect(alignment.check(@intFromPtr(bytes.*)));
    }
    try testing.expectEqual(@as(u64, taken.len * page_size), pages.stats().current_bytes);
    for (taken) |bytes| allocator.rawFree(bytes[0..1], alignment, @returnAddress());
    try testing.expectEqual(@as(u64, 0), pages.stats().current_bytes);
}

test "PageBacking leaves counters unchanged when its source refuses" {
    const page_size = std.heap.pageSize();
    var source: PageSource = .{};
    var pages: PageBacking = .{ .upstream = .{ .source = &source } };
    const allocator = pages.allocator();
    const byte_alignment = std.mem.Alignment.of(u8);

    const bytes = try allocator.alloc(u8, 16);
    defer allocator.free(bytes);
    const held: PageBacking.Stats = .{ .current_bytes = page_size, .peak_bytes = page_size };
    source.refuseAfter(0);
    source.refuseResizesAfter(0);

    try testing.expectError(error.OutOfMemory, allocator.alloc(u8, 16));
    try testing.expectEqual(held, pages.stats());

    try testing.expect(!allocator.rawResize(bytes, byte_alignment, 2 * page_size, @returnAddress()));
    try testing.expectEqual(held, pages.stats());

    try testing.expectEqual(@as(?[*]u8, null), allocator.rawRemap(bytes, byte_alignment, 2 * page_size, @returnAddress()));
    try testing.expectEqual(held, pages.stats());
    try testing.expect(source.has_induced_failure.load(.monotonic));
}

test "PageBacking returns every arena page on deinit" {
    var source: PageSource = .{};
    var pages: PageBacking = .{ .upstream = .{ .source = &source } };
    var first: Arena = .{ .pages = &pages };
    var second: Arena = .{ .pages = &pages };
    _ = try first.allocator().alloc(u8, 3 * std.heap.pageSize());
    const first_bytes = pages.stats().current_bytes;
    try testing.expect(first_bytes >= 3 * std.heap.pageSize());
    _ = try second.allocator().alloc(u8, 64);
    try testing.expect(pages.stats().current_bytes > first_bytes);
    second.deinit();
    try testing.expectEqual(first_bytes, pages.stats().current_bytes);
    first.deinit();
    try testing.expectEqual(@as(u64, 0), pages.stats().current_bytes);
}

test "scratch arenas reset at their documented boundaries and rebind safely" {
    var mem: Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();

    const frame_allocator = try mem.frameScratchAllocator();
    _ = try frame_allocator.allocator.alloc(u8, 128);
    try testing.expect(mem.frame.?.allocatedBytes() > 0);
    mem.beginFrame();
    try testing.expectEqual(@as(usize, 0), mem.frame.?.allocatedBytes());

    const table_allocator = try mem.tableScratchAllocator();
    _ = try table_allocator.allocator.alloc(u8, 64);
    try testing.expect(mem.scratch.?.allocatedBytes() > 0);
    _ = try mem.tableScratchAllocator();
    try testing.expectEqual(@as(usize, 0), mem.scratch.?.allocatedBytes());
}

test "scratch pages are charged to the work scope and a warm frame takes none" {
    var mem: Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    const pages = &mem.page_source;

    const frame = try mem.frameScratchAllocator();
    _ = try frame.allocator.alloc(u8, 256 * 1024);
    mem.beginFrame();
    _ = try frame.allocator.alloc(u8, 256 * 1024);
    mem.beginFrame();
    const allocations = pages.allocations.load(.monotonic);
    const deallocations = pages.deallocations.load(.monotonic);
    for (0..8) |_| {
        _ = try frame.allocator.alloc(u8, 256 * 1024);
        mem.beginFrame();
    }
    try testing.expectEqual(allocations, pages.allocations.load(.monotonic));
    try testing.expectEqual(deallocations, pages.deallocations.load(.monotonic));
    try testing.expect(mem.findScope(Atom.from(Memory.work_scope_name)).?.stats().backing.current_bytes >= 256 * 1024);

    _ = try frame.allocator.alloc(u8, 2 * Memory.scratch_retain_bytes);
    mem.beginFrame();
    try testing.expect(mem.frame.?.reserved() <= Memory.scratch_retain_bytes);
}

test "the memory report grows past its initial rows" {
    var mem: Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&mem);
    defer atoms.deinit();
    var tables: Table.Registry = undefined;
    try tables.init(&mem, 8);
    defer tables.deinit();

    for (0..300) |i| {
        var name_buf: [32]u8 = undefined;
        const owner = try std.fmt.bufPrint(&name_buf, "owner.{d}", .{i});
        _ = try mem.openScope(atoms.intern(owner));
    }
    try mem.syncTable(&tables, &atoms);
    const report = tables.findByName(atoms.intern(Memory.name)).?;
    // The tables arenas, every scope, and the host root above the interner's scope.
    const expected = Memory.table_arena_owners.len + mem.scopes.items.len + 1;
    try testing.expectEqual(@as(u32, @intCast(expected)), report.count());
}

/// Null for a root, whose row leaves the cell empty.
fn reportedParent(report: *Table, row: u32) ?Atom {
    const schema = report.getSchema();
    const field = schema.fields[schema.fieldIndex("parent").?];
    if (!report.rowHas(row, field.bit)) return null;
    var rows = report.query(struct { owner: *Atom, parent: *Atom });
    while (rows.next()) |candidate| {
        if (candidate.handle.row == row) return candidate.view.parent.*;
    }
    return null;
}

const ReportView = struct {
    owner: *Atom,
    kind: *Atom,
    capacity: *u64,
    allocated: *u64,
    reserved_pages: *u64,
    backing_bytes: *u64,
    peak_bytes: *u64,
    dynamic_arenas: *u64,
};

test "the memory report gives each scope its parent and wide totals" {
    var mem: Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&mem);
    defer atoms.deinit();
    var tables: Table.Registry = undefined;
    try tables.init(&mem, 8);
    defer tables.deinit();

    const root_atom = atoms.intern("root");
    const child_atom = atoms.intern("level");
    _ = try mem.openScope(root_atom);
    const child = mem.scopeFor(try mem.openChildScope(child_atom, root_atom)).?;
    const child_arena = try child.createArena();
    _ = try child_arena.allocator().alloc(u8, 512);
    // Past what a 32 bit column could hold: reserves no pages, only exercises the counter,
    // which release checks against the real pages again.
    const real_bytes = child.pages.current_bytes.load(.monotonic);
    child.pages.current_bytes.store(1 << 40, .monotonic);
    child.pages.peak_bytes.store(1 << 41, .monotonic);
    try mem.syncTable(&tables, &atoms);
    child.pages.current_bytes.store(real_bytes, .monotonic);
    const report = tables.findByName(atoms.intern(Memory.name)).?;
    var rows = report.query(ReportView);
    var seen: usize = 0;
    while (rows.next()) |row| {
        const owner = row.view.owner.*;
        if (owner == child_atom) {
            seen += 1;
            try testing.expectEqual(root_atom, reportedParent(report, row.handle.row).?);
            try testing.expectEqual(atoms.intern("scope"), row.view.kind.*);
            try testing.expectEqual(@as(u64, 512), row.view.allocated.*);
            try testing.expect(row.view.capacity.* >= 512);
            try testing.expectEqual(@as(u64, 1 << 40), row.view.backing_bytes.*);
            try testing.expectEqual(@as(u64, 1 << 41), row.view.peak_bytes.*);
            try testing.expectEqual(@as(u64, (1 << 40) / std.heap.pageSize()), row.view.reserved_pages.*);
            try testing.expectEqual(@as(u64, 1), row.view.dynamic_arenas.*);
        } else if (owner == root_atom) {
            seen += 1;
            try testing.expect(reportedParent(report, row.handle.row) == null);
        } else if (owner == Atom.from(Atom.Registry.scope_name)) {
            seen += 1;
            try testing.expectEqual(Atom.from(Memory.host_root_name), reportedParent(report, row.handle.row).?);
        } else if (owner == Atom.from(Memory.host_root_name)) {
            seen += 1;
            try testing.expect(reportedParent(report, row.handle.row) == null);
            try testing.expectEqual(@as(u64, 0), row.view.backing_bytes.*);
        }
    }
    try testing.expectEqual(@as(usize, 4), seen);
}

test "the memory report charges a scoped table's pages only to its scope" {
    var mem: Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&mem);
    defer atoms.deinit();
    var tables: Table.Registry = undefined;
    try tables.init(&mem, 8);
    defer tables.deinit();
    var schema: Table.Schema = undefined;
    try schema.init(testing.allocator, &atoms, 1);
    defer schema.deinit();
    schema.addField("value", u64, .int);

    const scope_atom = atoms.intern("level");
    const id = try mem.openScope(scope_atom);
    const unscoped_before = tables.storageStats();
    const handle = try tables.createScoped(id, &schema, 8, atoms.intern("level_rows"), .durable);
    try mem.syncTable(&tables, &atoms);
    const report = tables.findByName(atoms.intern(Memory.name)).?;
    // The report table is unscoped; only the scoped table's arena must be absent from these.
    const unscoped_after = tables.storageStats();
    try testing.expectEqual(unscoped_before.persistent.reserved_bytes, unscoped_after.persistent.reserved_bytes);
    var rows = report.query(ReportView);
    var charged: u64 = 0;
    while (rows.next()) |row| {
        if (row.view.owner.* == scope_atom) charged = row.view.backing_bytes.*;
    }
    try testing.expect(charged >= std.heap.pageSize());
    tables.destroy(handle);
    try mem.syncTable(&tables, &atoms);
    rows = report.query(ReportView);
    while (rows.next()) |row| {
        if (row.view.owner.* == scope_atom) try testing.expectEqual(@as(u64, 0), row.view.backing_bytes.*);
    }
}

test "Memory repeated syncTable plateaus all table arenas" {
    var mem: Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();

    var atoms: Atom.Registry = undefined;
    try atoms.init(&mem);
    defer atoms.deinit();

    var tables: Table.Registry = undefined;
    try tables.init(&mem, 8);
    defer tables.deinit();

    try mem.syncTable(&tables, &atoms);
    const reserved = tables.storageStats();
    const scratch_reserved = mem.scratch.?.reserved();

    for (0..100) |_| {
        try mem.syncTable(&tables, &atoms);
    }

    try testing.expectEqualDeep(reserved, tables.storageStats());
    try testing.expectEqual(scratch_reserved, mem.scratch.?.reserved());
}

test "Arena reports capacity and bytes handed out" {
    var source: PageSource = .{};
    var pages: PageBacking = .{ .upstream = .{ .source = &source } };
    var arena: Arena = .{ .pages = &pages };
    defer arena.deinit();
    const allocator = arena.allocator();
    try testing.expectEqual(@as(usize, 0), arena.allocatedBytes());
    _ = try allocator.alloc(u8, 512);
    try testing.expectEqual(@as(usize, 512), arena.allocatedBytes());
    try testing.expect(arena.reserved() >= 512);
    _ = try allocator.alloc(u8, 64);
    try testing.expectEqual(@as(usize, 512 + 64), arena.allocatedBytes());
    try testing.expect(arena.reset(.free_all));
    try testing.expectEqual(@as(usize, 0), arena.allocatedBytes());
    try testing.expectEqual(@as(usize, 0), arena.reserved());
}

test "Arena grows and takes back only its newest allocation" {
    var source: PageSource = .{};
    var pages: PageBacking = .{ .upstream = .{ .source = &source } };
    var arena: Arena = .{ .pages = &pages };
    defer arena.deinit();
    const allocator = arena.allocator();
    const older = try allocator.alloc(u8, 32);
    var newest = try allocator.alloc(u8, 32);
    try testing.expect(!allocator.resize(older, 64));
    try testing.expect(allocator.resize(older, 16));
    try testing.expect(allocator.resize(newest, 128));
    newest.len = 128;
    allocator.free(newest);
    const again = try allocator.alloc(u8, 8);
    try testing.expectEqual(newest.ptr, again.ptr);
}

test "Arena reset keeps chunks to its limit and reuses them before mapping more" {
    const page_size = std.heap.pageSize();
    var source: PageSource = .{};
    var pages: PageBacking = .{ .upstream = .{ .source = &source } };
    var arena: Arena = .{ .pages = &pages };
    defer arena.deinit();
    const allocator = arena.allocator();
    _ = try allocator.alloc(u8, 3 * page_size);
    _ = try allocator.alloc(u8, 9 * page_size);
    const capacity = arena.reserved();
    try testing.expect(arena.reset(.retain_capacity));
    try testing.expectEqual(capacity, arena.reserved());
    const mapped = source.allocations.load(.monotonic);
    _ = try allocator.alloc(u8, 9 * page_size);
    _ = try allocator.alloc(u8, 3 * page_size);
    try testing.expectEqual(mapped, source.allocations.load(.monotonic));

    try testing.expect(arena.reset(.{ .retain_with_limit = 10 * page_size }));
    try testing.expect(arena.reserved() <= 10 * page_size);
    try testing.expect(arena.reserved() > 0);
    try testing.expect(arena.reset(.free_all));
    try testing.expectEqual(@as(u64, 0), pages.stats().current_bytes);
}

test "Arena honors alignment past a page" {
    const page_size = std.heap.pageSize();
    var source: PageSource = .{};
    var pages: PageBacking = .{ .upstream = .{ .source = &source } };
    var arena: Arena = .{ .pages = &pages };
    defer arena.deinit();
    const alignment = std.mem.Alignment.fromByteUnits(4 * page_size);
    _ = try arena.allocator().alloc(u8, 3);
    const bytes = arena.rawAlloc(page_size, alignment).?;
    try testing.expect(alignment.check(@intFromPtr(bytes)));
}

test "Memory observes one Tables and detaches it by identity" {
    var mem: Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    var tables: Table.Registry = undefined;
    try tables.init(&mem, 8);
    try testing.expect(mem.observed_tables == &tables);
    try testing.expectError(error.AlreadyRegistered, mem.registerTables(&tables));
    var other: Table.Registry = undefined;
    try testing.expectError(error.ReservedOwner, mem.registerTables(&other));
    tables.deinit();
    try testing.expect(mem.observed_tables == null);
    for (Memory.table_arena_owners) |owner| try testing.expect(mem.tableArenaStats(owner) == null);
}

test "Memory observing Tables neither destroys nor resets their storage" {
    var mem: Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    var tables: Table.Registry = undefined;
    try tables.init(&mem, 8);
    const schema: Table.Schema = .{ .fields = &.{} };
    try tables.registerSchema(Atom.from("retained.schema"), &schema);
    const handle = try tables.createNamed(Atom.from("retained.schema"), 8, Atom.from("retained.table"), .persistent);
    const retained = tables.get(handle).?;
    const row = try retained.alloc();
    const before = tables.storageStats();
    for (Memory.table_arena_owners) |owner| try testing.expect(mem.tableArenaStats(owner) != null);
    try testing.expectEqualDeep(before, tables.storageStats());
    mem.unregisterTables(&tables);
    mem.unregisterTables(&tables);
    try testing.expect(mem.observed_tables == null);
    try testing.expectEqualDeep(before, tables.storageStats());
    try mem.registerTables(&tables);
    // Early observer shutdown neither destroys nor resets the table storage.
    mem.deinit();
    try testing.expectEqualDeep(before, tables.storageStats());
    // Storage and owned schemas remain usable without the observer or its allocator.
    try tables.grow(handle, 16);
    try testing.expect(retained.rowCapacity() >= 16);
    try testing.expectEqual(row.generation, retained.rowGeneration(row.row));
    try testing.expect(tables.getSchema(Atom.from("retained.schema")) != null);
    tables.deinit();
    try testing.expect(mem.observed_tables == null);
}

fn testPrivateScope(memory: *Memory) !*Scope {
    return memory.resolvedPrivateScope(Atom.from("test.records"));
}

test "Scope labeled record survives a protected release and an aborted admission" {
    var memory: Memory = undefined;
    memory.init(testing.allocator);
    defer memory.deinit();
    const scope = try testPrivateScope(&memory);
    const label = Atom.from("old");
    const old = try scope.labeledRecord(label, 64);
    try testing.expect(!old.installed);
    @memset(old.bytes, 42);
    old.installed = true;
    const token = try memory.beginInitAdmission();
    try testing.expectError(error.AdmissionAlreadyActive, memory.beginInitAdmission());
    try testing.expect(old == try scope.labeledRecord(label, 64));
    try testing.expectError(error.RecordTooSmall, scope.labeledRecord(label, 65));
    try memory.validateInitAdmission(token);
    scope.releaseLabeled(label);
    try testing.expect(!memory.commitInitAdmission(token));
    try testing.expectError(error.AdmissionMutationRejected, memory.validateInitAdmission(token));
    try testing.expect(memory.abortInitAdmission(token));
    try testing.expect(!memory.abortInitAdmission(token));
    try testing.expect(old == scope.existingLabeledRecord(label).?);
    try testing.expect(old.installed);
    try testing.expectEqual(@as(u8, 42), old.bytes[0]);
    const retry = try memory.beginInitAdmission();
    const new = Atom.from("new");
    _ = try scope.labeledRecord(new, 8);
    try memory.validateInitAdmission(retry);
    try testing.expect(memory.commitInitAdmission(retry));
    try testing.expect(!memory.commitInitAdmission(retry));
    try testing.expectError(error.InvalidAdmissionToken, memory.validateInitAdmission(token));
    try testing.expect(scope.existingLabeledRecord(new) != null);
    scope.releaseLabeled(new);
    try testing.expect(scope.existingLabeledRecord(new) == null);
    scope.releaseLabeled(new);
}

test "Scope labeled record and arena reserved in an admission leave with its abort" {
    var memory: Memory = undefined;
    memory.init(testing.allocator);
    defer memory.deinit();
    const before_scope = try testPrivateScope(&memory);
    const count = before_scope.stats().dynamic_arena_count;
    const token = try memory.beginInitAdmission();
    _ = try before_scope.labeledRecord(Atom.from("record"), 8);
    _ = try before_scope.labeledArena(Atom.from("arena"));
    try testing.expect(memory.abortInitAdmission(token));
    try testing.expectEqual(count, before_scope.stats().dynamic_arena_count);
    try testing.expect(before_scope.existingLabeledRecord(Atom.from("record")) == null);
    try testing.expect(before_scope.existingLabeledArena(Atom.from("arena")) == null);

    // A private scope first resolved inside an admission leaves with it, and nothing observes it.
    const opened_inside = Atom.from("test.opened_inside");
    const second = try memory.beginInitAdmission();
    const inside = try memory.resolvedPrivateScope(opened_inside);
    _ = try inside.labeledRecord(Atom.from("record"), 8);
    try testing.expect(memory.existingPrivateScope(opened_inside) == inside);
    try testing.expect(memory.abortInitAdmission(second));
    try testing.expect(memory.existingPrivateScope(opened_inside) == null);
}

test "Memory init admission keeps scratch content and restores missing scratch arenas" {
    var memory: Memory = undefined;
    memory.init(testing.allocator);
    defer memory.deinit();
    _ = try memory.tableScratchAllocator();
    _ = try memory.frameScratchAllocator();
    const scratch = memory.scratch.?;
    const frame = memory.frame.?;
    const bytes = try scratch.allocator().alloc(u8, 4);
    @memset(bytes, 37);
    const token = try memory.beginInitAdmission();
    _ = try memory.tableScratchAllocator();
    try testing.expectEqual(@as(u8, 37), bytes[0]);
    try testing.expectEqual(@as(usize, 4), scratch.allocatedBytes());
    memory.beginFrame();
    try testing.expectError(error.AdmissionMutationRejected, memory.validateInitAdmission(token));
    try testing.expect(memory.abortInitAdmission(token));
    try testing.expect(memory.scratch == scratch and memory.frame == frame);

    var empty: Memory = undefined;
    empty.init(testing.allocator);
    defer empty.deinit();
    const inside = try empty.beginInitAdmission();
    _ = try empty.tableScratchAllocator();
    _ = try empty.frameScratchAllocator();
    try testing.expect(empty.abortInitAdmission(inside));
    try testing.expect(empty.scratch == null and empty.frame == null);
}

test "Scope labeled record refusals leave nothing and a retry succeeds" {
    for (0..4) |fail_index| {
        var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
        var memory: Memory = undefined;
        memory.init(failing.allocator());
        defer memory.deinit();
        const token = try memory.beginInitAdmission();
        const refused = blk: {
            const scope = testPrivateScope(&memory) catch break :blk true;
            _ = scope.labeledRecord(Atom.from("new"), 16) catch break :blk true;
            break :blk false;
        };
        try testing.expect(refused or fail_index >= failing.allocations);
        try testing.expect(memory.abortInitAdmission(token));
        try testing.expectEqual(@as(usize, 0), memory.scopes.items.len);
        failing.fail_index = std.math.maxInt(usize);
        const retry = try memory.beginInitAdmission();
        const scope = try testPrivateScope(&memory);
        _ = try scope.labeledRecord(Atom.from("new"), 16);
        try memory.validateInitAdmission(retry);
        try testing.expect(memory.commitInitAdmission(retry));
    }
}

test "Memory init admission successful mutations invalidate validation without consuming token" {
    var memory: Memory = undefined;
    memory.init(testing.allocator);
    defer memory.deinit();
    const scope = try testPrivateScope(&memory);
    const token = try memory.beginInitAdmission();
    try memory.validateInitAdmission(token);
    const a = try scope.createArena();
    try testing.expect(!memory.commitInitAdmission(token));
    try testing.expectEqual(@as(usize, 1), scope.stats().dynamic_arena_count);
    try testing.expectError(error.AdmissionAlreadyActive, memory.beginInitAdmission());
    try memory.validateInitAdmission(token);
    scope.releaseArena(a);
    try testing.expect(!memory.commitInitAdmission(token));
    try testing.expectEqual(@as(usize, 0), scope.stats().dynamic_arena_count);
    _ = try scope.createArena();
    _ = try scope.createArena();
    try memory.validateInitAdmission(token);
    try testing.expect(memory.commitInitAdmission(token));
    try testing.expectEqual(@as(usize, 2), scope.stats().dynamic_arena_count);

    const retry = try memory.beginInitAdmission();
    try memory.validateInitAdmission(retry);
    _ = try scope.labeledRecord(Atom.from("abortable"), 16);
    try testing.expect(!memory.commitInitAdmission(retry));
    try testing.expect(memory.abortInitAdmission(retry));
    try testing.expectEqual(@as(usize, 2), scope.stats().dynamic_arena_count);
    try testing.expect(scope.existingLabeledRecord(Atom.from("abortable")) == null);
}

test "Memory init admission foreign and stale tokens preserve active state" {
    var memory: Memory = undefined;
    memory.init(testing.allocator);
    defer memory.deinit();
    var other: Memory = undefined;
    other.init(testing.allocator);
    defer other.deinit();
    const scope = try testPrivateScope(&memory);
    const retained = try scope.labeledRecord(Atom.from("retained"), 16);
    @memset(retained.bytes, 73);
    const previous = try memory.beginInitAdmission();
    const foreign = try other.beginInitAdmission();
    try testing.expectEqual(previous.generation, foreign.generation);
    try memory.validateInitAdmission(previous);
    const before = memory.admission.?;
    try testing.expectError(error.InvalidAdmissionToken, memory.validateInitAdmission(foreign));
    try testing.expect(!memory.commitInitAdmission(foreign));
    try testing.expect(!memory.abortInitAdmission(foreign));
    try testing.expectEqualDeep(before, memory.admission.?);
    try testing.expect(memory.abortInitAdmission(previous));
    const retry = try memory.beginInitAdmission();
    try memory.validateInitAdmission(retry);
    const retry_before = memory.admission.?;
    try testing.expectError(error.InvalidAdmissionToken, memory.validateInitAdmission(previous));
    try testing.expect(!memory.commitInitAdmission(previous));
    try testing.expect(!memory.abortInitAdmission(previous));
    try testing.expectEqualDeep(retry_before, memory.admission.?);
    try testing.expectEqual(@as(usize, 1), scope.stats().dynamic_arena_count);
    try testing.expectEqual(@as(u8, 73), retained.bytes[15]);
    try testing.expect(other.admission != null);
    try testing.expect(memory.commitInitAdmission(retry));
    try testing.expect(other.abortInitAdmission(foreign));
}

test "Memory init admission protects observing Tables and detaching them" {
    var memory: Memory = undefined;
    memory.init(testing.allocator);
    defer memory.deinit();
    var tables: Table.Registry = undefined;
    try tables.init(&memory, 8);
    defer tables.deinit();
    const stats = tables.storageStats();
    for (0..2) |operation| {
        const token = try memory.beginInitAdmission();
        try memory.validateInitAdmission(token);
        if (operation == 0) {
            try testing.expectError(error.AdmissionMutationRejected, memory.registerTables(&tables));
        } else {
            memory.unregisterTables(&tables);
        }
        try testing.expect(!memory.commitInitAdmission(token));
        try testing.expectError(error.AdmissionMutationRejected, memory.validateInitAdmission(token));
        try testing.expect(memory.observed_tables == &tables);
        for (Memory.table_arena_owners) |owner| try testing.expect(memory.tableArenaStats(owner) != null);
        try testing.expectEqualDeep(stats, tables.storageStats());
        try testing.expect(memory.abortInitAdmission(token));
        try testing.expectEqualDeep(stats, tables.storageStats());
    }
}

test "table arena telemetry reports exact columnar pages and singleton capacity without inventing pages" {
    var mem: Memory = undefined;
    mem.init(testing.allocator);
    defer mem.deinit();
    var atoms: Atom.Registry = undefined;
    try atoms.init(&mem);
    defer atoms.deinit();
    var tables: Table.Registry = undefined;
    try tables.init(&mem, 4);
    defer tables.deinit();
    var schema: Table.Schema = undefined;
    try schema.init(testing.allocator, &atoms, 1);
    defer schema.deinit();
    schema.addField("value", i32, .int);
    const ordinary = try tables.create(&schema, 1, atoms.intern("telemetry_rows"), .persistent);
    const singleton = try tables.createSingleton(&schema, atoms.intern("telemetry_singleton"), .durable);
    _ = try tables.get(singleton).?.alloc();
    const pages = mem.tableArenaStats("tables.persistent").?;
    try testing.expectEqual(@as(usize, 1), pages.reserved_pages);
    try testing.expectEqual(std.heap.pageSize(), pages.reserved_bytes);
    const scalar = mem.tableArenaStats("tables.singleton").?;
    try testing.expect(scalar.reserved_bytes > 0);
    try testing.expectEqual(@as(usize, 0), scalar.reserved_pages); // Unavailable, not a mapped-page count.
    try mem.syncTable(&tables, &atoms);
    const report = tables.findByName(atoms.intern(Memory.name)).?;
    const page_field = report.getSchema().fieldIndex("reserved_pages").?;
    var query = report.query(struct { owner: *Atom });
    var found = false;
    while (query.next()) |row| {
        if (row.view.owner.* != atoms.intern("tables.singleton")) continue;
        found = true;
        try testing.expect(!report.rowHas(row.handle.row, report.getSchema().fields[page_field].bit));
    }
    try testing.expect(found);
    tables.destroy(ordinary);
    try testing.expectEqual(@as(usize, 0), mem.tableArenaStats("tables.persistent").?.reserved_bytes);
    tables.destroy(singleton);
    try testing.expectEqual(scalar.reserved_bytes, mem.tableArenaStats("tables.singleton").?.reserved_bytes);
}
