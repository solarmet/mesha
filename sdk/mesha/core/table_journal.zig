//! The undo journal: a history of table edits as row images, kept as transactions that can
//! be cancelled, undone and redone. The figure runtime keeps one for its documents
//! (`runtime/figure/history.zig`). It is not the frame journal (`journal.zig`), and it changes
//! tables in place.
//!
//! A `Journal` holds entries, oldest first. Each is one transaction: the rows it recorded,
//! with an image of each before the transaction and, once committed, after it. An entry
//! belongs to a key, an atom the caller chooses (the figure runtime's is the document), and
//! `undo`, `redo` and `clear` act on one key's entries. Only one transaction is open at a
//! time, whatever its key.
//!
//! The order of calls: `begin`; then `touch` BEFORE writing a row, and `recordAlloc` /
//! `recordAllocAt` / `recordFree` instead of `Table.alloc` / `free`; then `commit`, or
//! `cancel` to put every recorded row back. A gesture that previews calls `resetPreview`
//! between previews to return to the rows as they were at `begin`. Mutations not recorded by
//! the active transaction are the caller's responsibility; do not replace schemas, shrink,
//! destroy tables, or externally mutate touched rows during a transaction.
//!
//! Keys select independent histories, not row ownership: callers enforce their doc
//! filter. Restores preflight every restored row before changing any table. Another
//! history may edit unrelated rows (including allocation/free); reusing or changing
//! a touched physical row produces `Conflict` rather than overwriting that history.
//!
//! A preview reset restores only rows touched since the previous reset, so `touch`
//! must precede every write in every preview cycle, even for rows recorded earlier.
//!
//! Growth is retained, not undone. Existing row images survive column relocation;
//! free-list restoration merges only touched rows of tables changed by `recordAlloc` /
//! `recordFree`, preserving unrelated entries, and never reorders value-only tables.
//! Without unrelated lifecycle changes/growth, row bytes and free-list order are
//! restored exactly. Table revisions are monotonic invalidation signals, not images.
//!
//! Each entry's row images live in a log block of the scope named at `begin`, taken at the
//! first recorded row. Consecutive small entries of one key share a block, because an
//! arena per entry costs a page each and, once its neighbours are gone, a process mapping
//! each, and the OS limits those. A block's pages return when its last entry ends, so
//! cancel, redo-branch discard, clear and eviction release them as whole blocks; the
//! newest entry also gives its bytes back to the block. Control records are in the journal's
//! node arena, not the scope, so metadata and ordering survive that scope's release. A
//! released scope has already taken its blocks: such an entry is never read, restoring it
//! gives `StaleTable`, and `clear` or eviction forgets it.
//!
//! Aggregate retention is policy, not storage: `Retention.unbounded` never evicts, and
//! `Retention.bytes` evicts oldest-first across every key.
//!
//! Keep the `Journal` itself in storage of the host's that outlasts a plugin's code. A code
//! reload leaves it as it is: it keeps arenas, which the host's code and a plugin's both call
//! directly, and no table pointers or allocator values. Call `rebind` after code reload, even
//! to clear an observer. Do not call the journal from an observer.
const std = @import("std");
const Atom = @import("atom.zig").Atom;
const memory_mod = @import("memory.zig");
const Table = @import("table.zig");

const Log = @import("log.zig").scope("table_journal");
/// This file's profile zones, in its log scope.
const Zone = enum { commit, preview_reset };
const Arena = memory_mod.Arena;
const Scope = memory_mod.Scope;
const Mask = Table.Mask;

/// Where an entry is in its life. `active`: the open transaction, between `begin` and
/// `commit` or `cancel`. `applied`: committed, or redone, and in effect in the tables.
/// `undone`: taken back by `undo`, and kept for `redo` until a later commit of its key
/// discards it.
pub const State = enum { active, applied, undone };
/// What the journal tells of one entry: a copy, valid whatever happens to the entry after.
pub const Metadata = struct {
    /// The entry's number, given at `begin`: they start at 1 and rise by one for each `begin`,
    /// and one is never given twice, so an entry is known by it after others are removed.
    sequence: u64,
    /// The history the entry belongs to, as passed to `begin` or set by `rekeyField`.
    key: Atom,
    /// What the caller passed to `begin` to name the edit. The journal only carries it.
    label: Atom,
    /// What the entry counts against `Retention.bytes`: its control record and every record
    /// in its log.
    bytes: usize,
    /// How many distinct rows the entry recorded.
    rows: u32,
    /// How many distinct tables those rows are in.
    tables: u32,
    /// Where the entry is in its life. For an entry just removed, the state it had.
    state: State,
};
/// What happened to an entry. `began`: `begin` opened it. `committed`: `commit` made it an
/// undo step. `cancelled`: `cancel` restored its rows and removed it, or `commit` removed it
/// for having recorded no row. `undone`, `redone`: `undo` and `redo` restored its rows.
/// `evicted`: retention removed it to make room. `discarded`: `clear` or `abandon` removed
/// it, or it was an undone entry and a commit of its key removed it.
pub const EventKind = enum { began, committed, cancelled, undone, redone, evicted, discarded };
/// One change to the journal's entries, as an `Observer` is told it: what happened and the
/// entry's metadata at that moment, for a removed entry as it was just before.
pub const Event = struct { kind: EventKind, entry: Metadata };
/// Whom the journal tells of each `Event`. `notify` is called inside the journal call that
/// causes the event, before it returns, and must not call the journal. Set with
/// `Journal.rebind`, and set again after a code reload, since `notify` points into code.
pub const Observer = struct {
    /// Passed back to `notify` as its first argument; the journal never reads it.
    context: ?*anyopaque = null,
    /// Called once for each event.
    notify: *const fn (?*anyopaque, Event) void,
};
/// What the aggregate of every key's entries may hold, active transaction included.
/// `bytes` counts control records and logged records, not mapped pages: a shared block is
/// held until its last entry leaves, and a log with its own block maps up to half again its
/// size. Pages can exceed the limit by that much.
pub const Retention = union(enum) {
    /// Nothing is evicted; history grows until memory runs out.
    unbounded,
    /// The most accounted bytes (`Journal.bytesUsed`) kept. Admitting more evicts the oldest
    /// entries of any key first, never the active one. Must be at least one control record's
    /// size, or `init` and `setRetention` fail with `BudgetExceeded`.
    bytes: usize,
};
/// What the journal's calls fail with. A call that fails has changed neither the tables nor
/// the history, except where its own comment says otherwise.
pub const Error = error{
    /// A transaction is open: `begin`, `undo` and `redo` need none open, `clear` and
    /// `rekeyField` none of the keys they name.
    TransactionOpen,
    /// No transaction is open, for a call that records into, ends or resets one.
    NoTransaction,
    /// The retention limit cannot hold what is asked beside the active entry, which is never
    /// evicted; a size overflowed; or a limit given is smaller than one control record.
    BudgetExceeded,
    /// A table handle names no table, or the entry's scope was released and its log with it.
    StaleTable,
    /// The row is not what the call needs: a row id past the table's capacity (`touch`), a
    /// handle that is not live (`recordFree`), or a free slot whose row is allocated
    /// (`recordAllocAt`).
    StaleRow,
    /// A recorded table's schema is not the one it had when the entry first recorded it; or,
    /// from `rekeyField`, the field is missing or its size is not the given values'.
    SchemaChanged,
    /// A recorded table's row capacity is below what it was when first recorded.
    CapacityChanged,
    /// The table's schema has a field holding a pointer, which a row image cannot keep.
    PointerField,
    /// A row is not as the entry left it, so `undo` or `redo` would overwrite another change;
    /// or, from `rekeyField`, the new key already has entries.
    Conflict,
    /// `recordAlloc` found no free row id that no retained entry holds an image of. Grow the
    /// table and call again.
    TableFull,
    /// `recordFree` of the row of a singleton that must keep it (`Table.required_singleton`).
    RequiredSingleton,
    /// The mask given to `markReferencedRows` is shorter than a referenced row id needs.
    InsufficientMask,
    /// `recordAllocAt`'s index is past the end of the table's reusable rows.
    InvalidFreeIndex,
    /// `recordAllocAt`'s row id has an image in a retained entry other than the active one,
    /// which reusing the id would overwrite.
    RowReserved,
    /// `undo` found no applied entry of the key, or `redo` no undone one.
    NoHistory,
    /// A control record or a log block could not be allocated.
    OutOfMemory,
    /// `begin`'s scope id names no scope.
    StaleScope,
    /// The entry's scope is closing: it takes no transaction, and a log in it cannot move to
    /// larger space.
    ScopeClosing,
    /// The call would create or release arenas, or change the retention policy, inside an
    /// active `Memory` init admission, which could not put that back if it aborted
    /// (`Memory.rejectInsideAdmission`). The admission is rejected too.
    AdmissionMutationRejected,
};

// Index slots and every `*_rel`, `*_head` and `*_next*` link are byte offsets into
// their entry's log, so a new generation copies the log unchanged. Zero means absent:
// the log's first bytes are reserved, never a record.
const first_record = alignment;
/// A fresh arena maps half again what it is asked for, plus headers: this request maps
/// 64 KiB, all of which a block then uses. The size trades release granularity against
/// mappings: an entry holds at most this much beyond its own bytes, and a session reaches
/// the OS's limit on mappings only after this much per mapping.
const block_request_bytes = 43520;
/// A log asking for over half a block takes a block of its own, so that one does not close
/// a block with most of its space unused.
const shared_log_limit = block_request_bytes / 2;
/// An entry's first space, so that its first few records do not each move it.
const initial_log_bytes = 512;

/// Log storage in one arena of `scope`, whose pages return when `live` reaches zero. The
/// record is host-side and survives that scope's release, when its arena is not followed.
const LogBlock = struct {
    scope: Scope.Id,
    key: Atom,
    arena: *Arena,
    bytes: []align(alignment) u8,
    /// Bytes handed to entries, newest last. Only the newest entry can extend or return its own.
    used: usize,
    live: u32 = 0,
    /// Linked in `Journal.open_blocks` while new entries of this key may start here.
    open: bool = false,
    previous_open: ?*LogBlock = null,
    next_open: ?*LogBlock = null,
};

/// Host-side control record, in the journal's node arena. Its log is in `scope`'s pages.
const Entry = struct {
    sequence: u64,
    key: Atom,
    label: Atom,
    rows: u32 = 0,
    tables: u32 = 0,
    state: State = .active,
    /// Current (table,row) lookup index; replaced indexes stay inert until removal.
    index_rel: usize = 0,
    /// Tables touched since the last preview reset; only the active entry has any.
    dirty_tables_head: usize = 0,
    scope: Scope.Id,
    /// Null until the first record, so an empty transaction allocates nothing.
    block: ?*LogBlock = null,
    /// Within `block`.
    log: []align(alignment) u8 = &.{},
    used: usize = first_record,
    previous: ?*Entry = null,
    next: ?*Entry = null,

    /// Accounted against retention: the control record and every logged record.
    fn accountedBytes(self: *const Entry) usize {
        return @sizeOf(Entry) + self.used - first_record;
    }

    fn metadata(self: *const Entry) Metadata {
        return .{ .sequence = self.sequence, .key = self.key, .label = self.label, .bytes = self.accountedBytes(), .rows = self.rows, .tables = self.tables, .state = self.state };
    }

    fn at(self: *const Entry, comptime T: type, offset: usize) *T {
        return @ptrCast(@alignCast(self.log[offset..][0..@sizeOf(T)].ptr));
    }

    fn image(self: *const Entry, offset: usize, side: ImageSide) []u8 {
        const size = self.at(RowRecord, offset).image_size;
        const side_offset: usize = switch (side) {
            .before => 0,
            .after => size,
        };
        return self.log[offset + @sizeOf(RowRecord) + side_offset ..][0..size];
    }

    fn freeRows(self: *const Entry, offset: usize) []u32 {
        const count = self.at(FreeRecord, offset).free_count;
        const bytes = self.log[offset + @sizeOf(FreeRecord) ..][0 .. @as(usize, count) * @sizeOf(u32)];
        return std.mem.bytesAsSlice(u32, @as([]align(4) u8, @alignCast(bytes)));
    }

    /// Current lookup slots; null before the entry's first record.
    fn indexSlots(self: *const Entry) ?[]usize {
        if (self.index_rel == 0) return null;
        const capacity = self.at(IndexRecord, self.index_rel).capacity;
        const bytes = self.log[self.index_rel + @sizeOf(IndexRecord) ..][0 .. capacity * @sizeOf(usize)];
        return std.mem.bytesAsSlice(usize, @as([]align(@alignOf(usize)) u8, @alignCast(bytes)));
    }

    /// The key must be absent; the index always keeps a free slot.
    fn indexInsert(self: *const Entry, record: usize) void {
        const slots = self.indexSlots().?;
        const mask = slots.len - 1;
        var slot = hashKey(self.recordKey(record)) & mask;
        while (slots[slot] != 0) slot = (slot + 1) & mask;
        slots[slot] = record;
    }

    /// Offset of the table or row record for `key`, if recorded.
    fn findRecord(self: *const Entry, key: IndexKey) ?usize {
        const slots = self.indexSlots() orelse return null;
        const mask = slots.len - 1;
        var slot = hashKey(key) & mask;
        // At most half the slots are occupied, so every probe reaches an empty slot.
        while (slots[slot] != 0) : (slot = (slot + 1) & mask) {
            if (std.meta.eql(self.recordKey(slots[slot]), key)) return slots[slot];
        }
        return null;
    }
    fn findTable(self: *const Entry, handle: Table.Handle) ?usize {
        return self.findRecord(.{ .kind = .table, .handle = handle });
    }
    fn findRow(self: *const Entry, handle: Table.Handle, row: u32) ?usize {
        return self.findRecord(.{ .kind = .row, .handle = handle, .row = row });
    }

    fn recordKey(self: *const Entry, offset: usize) IndexKey {
        return switch (self.at(Record, offset).kind) {
            .table => .{ .kind = .table, .handle = self.at(TableRecord, offset).handle },
            .row => .{ .kind = .row, .handle = self.at(RowRecord, offset).handle, .row = self.at(RowRecord, offset).row },
            .before_free, .after_free, .index => unreachable,
        };
    }
};
const RecordKind = enum { table, row, before_free, after_free, index };
const Record = struct { size: usize, kind: RecordKind };
// Each record begins with the same header; all offsets and sizes are 8-aligned.
const TableRecord = struct {
    header: Record,
    handle: Table.Handle,
    schema: u64,
    /// First-touch capacity; restores reject tables that no longer reach it.
    capacity: u32,
    /// Reusable IDs captured just before the first journal allocation/free and at
    /// commit. A before snapshot marks the transaction as lifecycle-changing.
    before_free_rel: usize = 0,
    after_free_rel: usize = 0,
    dirty_rows_head: usize = 0,
    dirty_next_table: usize = 0,
    dirty: bool = false,
    /// A journal allocation/free changed reusable IDs since the last preview reset.
    cycle_lifecycle: bool = false,
};
const RowRecord = struct {
    header: Record,
    handle: Table.Handle,
    row: u32,
    image_size: usize,
    dirty_next: usize = 0,
    dirty: bool = false,
};
/// Ordered reusable IDs with their own capture-time capacity.
const FreeRecord = struct {
    header: Record,
    handle: Table.Handle,
    capacity: u32,
    free_count: u32,
};
/// Followed by `capacity` linear-probing slots; at most half are occupied.
const IndexRecord = struct {
    header: Record,
    capacity: usize,
};
comptime {
    std.debug.assert(@offsetOf(TableRecord, "header") == 0);
    std.debug.assert(@offsetOf(RowRecord, "header") == 0);
    std.debug.assert(@offsetOf(FreeRecord, "header") == 0);
    std.debug.assert(@offsetOf(IndexRecord, "header") == 0);
}
const IndexKey = struct { kind: RecordKind, handle: Table.Handle, row: u32 = 0 };
const TouchKind = enum { value, lifecycle };
const RestoreSelection = enum { all, cycle_dirty };
const ImageSide = enum { before, after };
const Liveness = enum { dead, live };
const initial_index_capacity = 8;
const alignment = 8;

/// The history itself: every key's entries in one chronological list, the open transaction
/// among them. See the file's comment for the order of calls. Its fields are its own state;
/// read them through its functions. Not safe to call from two threads at once.
pub const Journal = struct {
    /// Where entries' scopes are looked up and admissions checked. Must outlive the journal.
    memory: *memory_mod.Memory,
    /// Control records. Removed ones are reused from `free_nodes`, so this holds the peak
    /// entry count until its owner releases it.
    nodes: *Arena,
    /// Control records of removed entries, linked by `next`, for `begin` to take first.
    free_nodes: ?*Entry = null,
    /// At most one per scope and key. Removed block records are reused, like entries.
    open_blocks: ?*LogBlock = null,
    /// Block records with no entry left, linked by `next_open`, for reuse.
    free_blocks: ?*LogBlock = null,
    /// The oldest entry; null when there is none.
    first: ?*Entry = null,
    /// The newest entry, which is the active one while a transaction is open.
    last: ?*Entry = null,
    /// How many entries are linked, the active one included.
    count: usize = 0,
    /// Accounted bytes of every entry, including those of released scopes until forgotten.
    used: usize = 0,
    /// The open transaction's entry; null between transactions.
    active: ?*Entry = null,
    /// The `Metadata.sequence` the next `begin` gives.
    next_sequence: u64 = 1,
    /// Advances on every change, so a prepared plan detects one without hashing history.
    revision: u64 = 0,
    /// What the entries together may hold; change it with `setRetention`.
    retention: Retention,
    /// Whom to tell of each event; set with `rebind`.
    observer: ?Observer = null,

    /// An empty journal. `nodes` holds the control records and is the caller's to release,
    /// after `releaseAll`; `memory` and `nodes` must outlive the journal. A code reload must
    /// reuse the `Journal`, not initialize it again. Allocates nothing until the first entry.
    /// Retention covers all entries, metadata, indexes, before/after images, and the active
    /// transaction; making room may evict history during preview, even if later cancelled.
    /// Fails with `error.BudgetExceeded` when a `bytes` limit is below one control record.
    pub fn init(memory: *memory_mod.Memory, nodes: *Arena, retention: Retention) !Journal {
        switch (retention) {
            .unbounded => {},
            .bytes => |limit| if (limit < @sizeOf(Entry)) return error.BudgetExceeded,
        }
        return .{ .memory = memory, .nodes = nodes, .retention = retention };
    }

    /// Sets whom the journal tells of its events, or with null no one. Call it after a code
    /// reload, when the observer kept points into code that is gone.
    pub fn rebind(self: *Journal, observer: ?Observer) void {
        self.observer = observer;
    }

    /// Changes what the entries together may hold. Takes effect at once: a smaller limit
    /// evicts oldest-first, never the active entry, telling the observer of each. Fails with
    /// `BudgetExceeded` for a limit below one control record, and with
    /// `AdmissionMutationRejected` inside an init admission; nothing has changed then.
    pub fn setRetention(self: *Journal, retention: Retention) Error!void {
        switch (retention) {
            .unbounded => {},
            .bytes => |limit| if (limit < @sizeOf(Entry)) return error.BudgetExceeded,
        }
        // An aborted admission could not restore the policy or anything it evicted.
        try self.memory.rejectInsideAdmission();
        self.retention = retention;
        self.revision +%= 1;
        self.evictFor(0);
    }

    /// Returns every entry's pages and forgets it, active included, without restoring
    /// rows or telling the observer. For owner teardown; the caller then releases the node
    /// arena.
    pub fn releaseAll(self: *Journal) void {
        var it = self.first;
        while (it) |item| : (it = item.next) self.releaseLog(item);
        self.first = null;
        self.last = null;
        self.count = 0;
        self.used = 0;
        self.active = null;
        self.free_nodes = null;
        self.revision +%= 1;
    }

    /// The accounted bytes of every entry, the active one included: what `Retention.bytes`
    /// limits. Control records and logged records, not mapped pages.
    pub fn bytesUsed(self: *const Journal) usize {
        return self.used;
    }

    /// Whether a transaction is open, of any key.
    pub fn inTransaction(self: *const Journal) bool {
        return self.active != null;
    }

    /// The open transaction's metadata as it is so far; null when none is open.
    pub fn activeEntry(self: *const Journal) ?Metadata {
        const item = self.active orelse return null;
        return item.metadata();
    }

    /// Includes the active transaction, if any; enumeration order is chronological.
    pub fn entryCount(self: *const Journal) usize {
        return self.count;
    }

    /// Walks the entries oldest first, the active one last. It points into the journal: any call
    /// that adds or removes an entry ends its use.
    pub const Iterator = struct {
        /// The entry `next` gives; null at the end.
        current: ?*const Entry,
        /// The next entry's metadata, or null after the newest.
        pub fn next(self: *Iterator) ?Metadata {
            const item = self.current orelse return null;
            self.current = item.next;
            return item.metadata();
        }
    };

    /// Chronological. Prefer this to `entry` when walking: a walk by index is quadratic.
    pub fn iterator(self: *const Journal) Iterator {
        return .{ .current = self.first };
    }

    /// The metadata of entry `index`, counting from the oldest at 0; null past the newest. Costs a
    /// walk of `index` entries.
    pub fn entry(self: *const Journal, index: usize) ?Metadata {
        const item = self.entryAt(index) orelse return null;
        return item.metadata();
    }

    /// The handle of the `table_index`th table that entry `index` recorded, in the order it
    /// first touched them; `Metadata.tables` says how many there are. The handle may name a
    /// table since destroyed. Null past either end, and when the entry's scope was released
    /// with its log.
    pub fn entryTable(self: *const Journal, index: usize, table_index: usize) ?Table.Handle {
        const item = self.entryAt(index) orelse return null;
        if (!self.logAvailable(item)) return null;
        var record: usize = first_record;
        var i: usize = 0;
        while (record < item.used) : (record += item.at(Record, record).size) {
            if (item.at(Record, record).kind != .table) continue;
            if (i == table_index) return item.at(TableRecord, record).handle;
            i += 1;
        }
        return null;
    }

    /// Opens a transaction of `key`, appending its entry and telling the observer `began`.
    /// `label` names the edit and is only carried in the metadata. Nothing is allocated for
    /// the log until the first recorded row. The scope is the entry's owner for its whole
    /// life, its row images in that scope's pages; a closing one takes no new work. Under a
    /// `bytes` limit this may evict the oldest entries. Fails with `TransactionOpen` when one
    /// is open under any key, `StaleScope`, `ScopeClosing`, `BudgetExceeded`, `OutOfMemory`
    /// and `AdmissionMutationRejected`.
    pub fn begin(self: *Journal, scope_id: Scope.Id, key: Atom, label: Atom) Error!void {
        if (self.active != null) return error.TransactionOpen;
        const scope = self.memory.scopeFor(scope_id) orelse return error.StaleScope;
        if (scope.state != .open) return error.ScopeClosing;
        try self.checkRetention(@sizeOf(Entry));
        const item = try self.takeNode();
        self.evictFor(@sizeOf(Entry));
        item.* = .{ .sequence = self.next_sequence, .key = key, .label = label, .scope = scope_id, .previous = self.last };
        if (self.last) |last| last.next = item else self.first = item;
        self.last = item;
        self.count += 1;
        self.used += @sizeOf(Entry);
        self.next_sequence +%= 1;
        self.active = item;
        self.revision +%= 1;
        self.emit(.began, item.metadata());
    }

    /// Records the row as it is, to be called before the caller writes it. `row` is the row's
    /// id (`RowHandle.row`), which need not be allocated. Captures all column bytes, including
    /// fields absent from the row's mask, and the row's mask, generation and liveness.
    /// Repeated calls for the same table/row consume no additional log space, but
    /// each one marks the row for the next preview reset. The table's payloads are pinned
    /// from here on (`Table.pinPayloads`), since an image keeps payload cells by offset.
    /// Admission errors occur before the caller's mutation; cancel remains available. Fails
    /// with `NoTransaction`, `StaleTable`, `StaleRow` for an id past the table's capacity,
    /// `SchemaChanged` and `CapacityChanged` for a table changed since the entry first
    /// recorded it, `PointerField`, `BudgetExceeded`, `OutOfMemory`, `ScopeClosing` and
    /// `AdmissionMutationRejected`. Under a `bytes` limit it may evict other entries.
    pub fn touch(self: *Journal, tables: *Table.Registry, handle: Table.Handle, row: u32) Error!void {
        return self.prepareTouch(tables, handle, row, .value);
    }

    /// Records the row's first before-image and, before the first lifecycle change,
    /// the table's reusable IDs. All bytes are reserved before the log or table
    /// changes, then the row joins the current preview cycle.
    fn prepareTouch(self: *Journal, tables: *Table.Registry, handle: Table.Handle, row: u32, kind: TouchKind) Error!void {
        const item = self.active orelse return error.NoTransaction;
        if (!self.logAvailable(item)) return error.StaleTable;
        const table = tables.get(handle) orelse return error.StaleTable;
        if (row >= table.rowCapacity()) return error.StaleRow;
        // A row image keeps the row's payload cells by their offsets.
        table.pinPayloads();
        const existing_table = item.findTable(handle);
        if (existing_table) |table_rel| try validateTable(table, item.at(TableRecord, table_rel));
        const existing_row = item.findRow(handle, row);

        var reservation: usize = 0;
        var schema: u64 = 0;
        if (existing_table == null) {
            schema = try fingerprint(table);
            reservation = padded(@sizeOf(TableRecord));
        }
        var image_size: usize = 0;
        var row_size: usize = 0;
        if (existing_row == null) {
            image_size = rowImageSize(table);
            row_size = try recordSize(@sizeOf(RowRecord), 2, image_size);
            reservation = try addSize(reservation, row_size);
        }
        const new_keys = @as(usize, @intFromBool(existing_table == null)) + @intFromBool(existing_row == null);
        const index_capacity = try grownIndexCapacity(item, new_keys);
        var index_size: usize = 0;
        if (index_capacity) |capacity| {
            index_size = try recordSize(@sizeOf(IndexRecord), capacity, @sizeOf(usize));
            reservation = try addSize(reservation, index_size);
        }
        var first_lifecycle = kind == .lifecycle;
        if (existing_table) |table_rel| {
            if (item.at(TableRecord, table_rel).before_free_rel != 0) first_lifecycle = false;
        }
        if (first_lifecycle) reservation = try addSize(reservation, try freeSnapshotSize(table));
        if (reservation != 0) try self.reserve(item, reservation);

        if (index_capacity) |capacity| self.replaceIndex(item, capacity, index_size);
        const table_rel = existing_table orelse blk: {
            const offset = self.append(item, padded(@sizeOf(TableRecord)));
            item.at(TableRecord, offset).* = .{
                .header = .{ .size = padded(@sizeOf(TableRecord)), .kind = .table },
                .handle = handle,
                .schema = schema,
                .capacity = table.rowCapacity(),
            };
            item.tables += 1;
            item.indexInsert(offset);
            break :blk offset;
        };
        const row_rel = existing_row orelse blk: {
            const offset = self.append(item, row_size);
            item.at(RowRecord, offset).* = .{
                .header = .{ .size = row_size, .kind = .row },
                .handle = handle,
                .row = row,
                .image_size = image_size,
            };
            capture(table, row, item.image(offset, .before));
            item.rows += 1;
            item.indexInsert(offset);
            break :blk offset;
        };
        const table_record = item.at(TableRecord, table_rel);
        // Value edits never change allocator order, so a snapshot taken just
        // before the first journal allocation/free is the transaction's origin.
        if (first_lifecycle) table_record.before_free_rel = self.appendFreeSnapshot(item, .before_free, handle, table);

        const row_record = item.at(RowRecord, row_rel);
        if (!table_record.dirty) {
            table_record.dirty = true;
            table_record.dirty_next_table = item.dirty_tables_head;
            item.dirty_tables_head = table_rel;
        }
        if (!row_record.dirty) {
            row_record.dirty = true;
            row_record.dirty_next = table_record.dirty_rows_head;
            table_record.dirty_rows_head = row_rel;
        }
        if (kind == .lifecycle) table_record.cycle_lifecycle = true;
        self.revision +%= 1;
    }

    /// Whether a retained entry holds an image of row id `row` of the table, so that reusing
    /// the id would put another row where that entry restores one. `ignore_active` leaves the
    /// open transaction's entry out. Allocates nothing; the table is matched by its whole
    /// handle, generation included. O(entries): each entry answers from its index.
    pub fn referencesRow(self: *const Journal, handle: Table.Handle, row: u32, ignore_active: bool) bool {
        var it = self.first;
        while (it) |item| : (it = item.next) {
            if (ignore_active and self.active == item) continue;
            if (!self.logAvailable(item)) continue;
            if (item.findRow(handle, row) != null) return true;
        }
        return false;
    }

    /// `referencesRow` for every row id of the table at once: clears `reserved`, then sets
    /// `reserved[id]` for each row id a retained entry holds an image of. `reserved` is the
    /// caller's and needs an element for every such id, the table's row capacity being
    /// enough; a shorter one fails with `InsufficientMask`, explicitly. On failure the mask
    /// may be partially marked, but history/tables never change. `ignore_active` leaves the
    /// open transaction's entry out.
    pub fn markReferencedRows(self: *const Journal, handle: Table.Handle, reserved: []bool, ignore_active: bool) Error!void {
        @memset(reserved, false);
        try self.markWindow(handle, 0, reserved, ignore_active, true);
    }

    fn markWindow(self: *const Journal, handle: Table.Handle, base: usize, reserved: []bool, ignore_active: bool, require_coverage: bool) Error!void {
        var it = self.first;
        while (it) |item| : (it = item.next) {
            if (ignore_active and self.active == item) continue;
            if (!self.logAvailable(item)) continue;
            // Tables belong to one document, so most of a long history is skipped here.
            if (item.findTable(handle) == null) continue;
            var offset: usize = first_record;
            while (offset < item.used) : (offset += item.at(Record, offset).size) {
                if (item.at(Record, offset).kind != .row) continue;
                const record = item.at(RowRecord, offset);
                if (!std.meta.eql(record.handle, handle)) continue;
                if (record.row >= base and record.row - base < reserved.len) {
                    reserved[record.row - base] = true;
                } else if (require_coverage) return error.InsufficientMask;
            }
        }
    }

    /// Allocates the row id at `free_index` of the table's reusable rows
    /// (`Table.reusableRows`) and records it, so cancel and undo free it again. Returns the
    /// row's handle; its cells are the caller's to write.
    /// Validates before admission; bounded retention may evict other entries here.
    /// Rejection leaves table bytes, generations and free-list order untouched. Fails with
    /// `NoTransaction`, `StaleTable`, `InvalidFreeIndex`, `StaleRow`, `RowReserved` when an
    /// entry other than the active one holds an image of the id, and as `touch` does.
    pub fn recordAllocAt(self: *Journal, tables: *Table.Registry, handle: Table.Handle, free_index: usize) Error!Table.RowHandle {
        if (self.active == null) return error.NoTransaction;
        const table = tables.get(handle) orelse return error.StaleTable;
        if (free_index >= table.reusableRows().len) return error.InvalidFreeIndex;
        const row = table.reusableRows().at(free_index);
        if (row >= table.rowCapacity() or table.isAllocated(row)) return error.StaleRow;
        if (self.referencesRow(handle, row, true)) return error.RowReserved;
        try self.prepareTouch(tables, handle, row, .lifecycle);
        return table.allocRowId(row) catch unreachable;
    }

    /// `recordAllocAt` at a free row id of the journal's choosing: the last reusable row that
    /// no retained entry but the active one holds an image of, preserving all other ordering.
    /// Fast path O(entries), when the last reusable row is eligible. Otherwise it scans
    /// without allocating, 256 stack booleans at a time: O(ceil(capacity/256)*(J+F)) for J
    /// journal records and F free rows, skipping empty windows. A caller with an allocator
    /// does better with one `markReferencedRows` scan of a mask it owns and `recordAllocAt`,
    /// O(J+capacity+F), as the figure runtime does.
    /// No eligible slot returns `TableFull` without eviction; grow explicitly.
    pub fn recordAlloc(self: *Journal, tables: *Table.Registry, handle: Table.Handle) Error!Table.RowHandle {
        if (self.active == null) return error.NoTransaction;
        const table = tables.get(handle) orelse return error.StaleTable;
        const free_rows = table.reusableRows();
        if (free_rows.len == 0) return error.TableFull;
        if (!self.referencesRow(handle, free_rows.at(free_rows.len - 1), true))
            return self.recordAllocAt(tables, handle, free_rows.len - 1);
        var best: ?usize = null;
        var base: usize = 0;
        while (base < table.rowCapacity()) {
            const count = @min(@as(usize, table.rowCapacity()) - base, 256);
            var has_free = false;
            for (0..free_rows.len) |free_i| {
                const row = free_rows.at(free_i);
                if (row >= base and row - base < count) {
                    has_free = true;
                    break;
                }
            }
            if (has_free) {
                var mask: [256]bool = @splat(false);
                try self.markWindow(handle, base, mask[0..count], true, false);
                for (0..free_rows.len) |i| {
                    const row = free_rows.at(i);
                    if (row >= base and row - base < count and !mask[row - base] and (best == null or i > best.?)) best = i;
                }
            }
            base += count;
        }
        return self.recordAllocAt(tables, handle, best orelse return error.TableFull);
    }

    /// Records the row as it is and frees it, so cancel and undo bring it back with its values and
    /// its handle. Fails with `NoTransaction`, `StaleTable`, `StaleRow` for a handle that is not
    /// live, `RequiredSingleton`, and as `touch` does; the row is then not freed.
    pub fn recordFree(self: *Journal, tables: *Table.Registry, handle: Table.Handle, row: Table.RowHandle) Error!void {
        if (self.active == null) return error.NoTransaction;
        const table = tables.get(handle) orelse return error.StaleTable;
        if (!table.valid(row)) return error.StaleRow;
        if (table.required_singleton) return error.RequiredSingleton;
        try self.prepareTouch(tables, handle, row.row, .lifecycle);
        table.free(row);
    }

    /// Ends the open transaction as an undo step: captures every recorded row as it is now,
    /// the image `redo` restores, removes the key's undone entries (`discarded`), and tells
    /// the observer `committed`. The tables are not changed.
    /// On failure the transaction stays open and cancel is still possible unless
    /// the caller invalidated its tables/schema. Empty commits create no undo step: the
    /// entry is removed and the observer told `cancelled`. Fails with `NoTransaction`,
    /// `StaleTable`, `SchemaChanged`, `CapacityChanged`, `BudgetExceeded`, `OutOfMemory`,
    /// `ScopeClosing` and `AdmissionMutationRejected`.
    pub fn commit(self: *Journal, tables: *Table.Registry) Error!void {
        const trace_zone = Log.zone(Zone.commit);
        defer trace_zone.end();
        const item = self.active orelse return error.NoTransaction;
        try self.preflight(tables, item, .all, null);
        // An empty commit creates no undo step, so it prunes nothing.
        if (item.rows != 0) {
            var redo_entry = self.first;
            while (redo_entry) |undone| : (redo_entry = undone.next) {
                if (undone.key == item.key and undone.state == .undone) try self.rejectRelease(undone);
            }
        }
        // Only lifecycle tables need their committed reusable order for redo.
        var extra: usize = 0;
        var record: usize = first_record;
        while (record < item.used) : (record += item.at(Record, record).size) {
            if (item.at(Record, record).kind != .table) continue;
            const table_record = item.at(TableRecord, record);
            if (table_record.before_free_rel == 0) continue;
            const snapshot_size = try freeSnapshotSize(tables.get(table_record.handle).?);
            extra = try addSize(extra, snapshot_size);
        }
        if (extra != 0) try self.reserve(item, extra);
        const original_end = item.used;
        record = first_record;
        while (record < original_end) : (record += item.at(Record, record).size) {
            switch (item.at(Record, record).kind) {
                .table => {
                    const table_record = item.at(TableRecord, record);
                    if (table_record.before_free_rel != 0) {
                        const table = tables.get(table_record.handle).?;
                        table_record.after_free_rel = self.appendFreeSnapshot(item, .after_free, table_record.handle, table);
                    }
                },
                .row => {
                    const row = item.at(RowRecord, record);
                    capture(tables.get(row.handle).?, row.row, item.image(record, .after));
                },
                .before_free, .index => {},
                .after_free => unreachable,
            }
        }
        clearDirty(item);
        self.revision +%= 1;
        if (item.rows == 0) {
            self.endActive(item, .cancelled);
            return;
        }
        self.removeUndone(item.key, .discarded);
        trimLog(item);
        item.state = .applied;
        self.active = null;
        self.emit(.committed, item.metadata());
    }

    /// Ends the open transaction by putting every row it recorded back as first recorded, rows it
    /// allocated freed and rows it freed live again, then removes the entry and tells the observer
    /// `cancelled`. Every row is checked before any is restored. Fails with `NoTransaction`,
    /// `StaleTable`, `SchemaChanged`, `CapacityChanged` and `AdmissionMutationRejected`; the
    /// transaction then stays open, and `abandon` ends it where the tables are gone.
    pub fn cancel(self: *Journal, tables: *Table.Registry) Error!void {
        const item = self.active orelse return error.NoTransaction;
        try self.preflight(tables, item, .all, null);
        try self.rejectRelease(item);
        restore(tables, item, .all, .before);
        self.revision +%= 1;
        self.endActive(item, .cancelled);
    }

    /// Takes back the key's newest applied entry: restores its rows to their images from before
    /// it, marks it `undone` and tells the observer. Returns its metadata. Each row must be as the
    /// entry left it, or nothing is restored and it fails with `Conflict`. Also fails with
    /// `TransactionOpen` while any transaction is open, `NoHistory`, `StaleTable`, `SchemaChanged`
    /// and `CapacityChanged`.
    pub fn undo(self: *Journal, tables: *Table.Registry, key: Atom) Error!Metadata {
        if (self.active != null) return error.TransactionOpen;
        const item = self.historyEntry(key, .applied) orelse return error.NoHistory;
        try self.preflight(tables, item, .all, .after);
        restore(tables, item, .all, .before);
        item.state = .undone;
        self.revision +%= 1;
        const info = item.metadata();
        self.emit(.undone, info);
        return info;
    }

    /// Applies again the key's oldest undone entry, the one undone last: restores its rows to
    /// their images from its commit, marks it `applied` and tells the observer. Returns its
    /// metadata. Each row must be as `undo` left it, or it fails with `Conflict`; its other
    /// failures are `undo`'s.
    pub fn redo(self: *Journal, tables: *Table.Registry, key: Atom) Error!Metadata {
        if (self.active != null) return error.TransactionOpen;
        const item = self.historyEntry(key, .undone) orelse return error.NoHistory;
        try self.preflight(tables, item, .all, .before);
        restore(tables, item, .all, .after);
        item.state = .applied;
        self.revision +%= 1;
        const info = item.metadata();
        self.emit(.redone, info);
        return info;
    }

    /// Puts the rows touched since the last reset back as first recorded, for a gesture that
    /// applies each preview to the rows as they were at `begin`.
    /// Restore the active gesture origin without ending the transaction. Before-images
    /// remain recorded once, allowing absolute (non-compounding) pointer previews.
    /// Rows untouched since the previous reset are already at the origin, so only the
    /// current cycle's rows are restored; a reset without touches does no row work. Fails
    /// with `NoTransaction`, `StaleTable`, `SchemaChanged` and `CapacityChanged`, restoring
    /// nothing.
    pub fn resetPreview(self: *Journal, tables: *Table.Registry) Error!void {
        const trace_zone = Log.zone(Zone.preview_reset);
        defer trace_zone.end();
        const item = self.active orelse return error.NoTransaction;
        try self.preflight(tables, item, .cycle_dirty, null);
        restore(tables, item, .cycle_dirty, .before);
        clearDirty(item);
        self.revision +%= 1;
    }

    /// Forgets every entry of `key`, applied and undone, without changing a table, telling the
    /// observer `discarded` for each. Fails with `TransactionOpen` when the open transaction is
    /// this key's, and `AdmissionMutationRejected`; nothing is forgotten then.
    pub fn clear(self: *Journal, key: Atom) Error!void {
        if (self.active) |active| if (active.key == key) return error.TransactionOpen;
        var checked = self.first;
        while (checked) |item| : (checked = item.next) {
            if (item.key == key) try self.rejectRelease(item);
        }
        var it = self.first;
        while (it) |item| {
            it = item.next;
            if (item.key == key) self.remove(item, .discarded);
        }
    }

    /// Rename a logical history owner and an identity field in its before/after images.
    /// The caller changes the corresponding live fields only after this succeeds.
    /// This supports Save As without discarding undo or introducing allocator callbacks.
    /// Every entry of `old_key` becomes `new_key`'s, and in each of its row images the cell
    /// of the field `field_name` is set to `after` where its bytes equal `before`; the two
    /// are the field's raw bytes and must be its size. Every table an entry recorded must
    /// have the field. Does nothing when the keys are equal. Fails with `TransactionOpen`
    /// when the open transaction is of either key, `SchemaChanged` for a missing field or a
    /// size that differs, `Conflict` when `new_key` already has entries, `StaleTable` and
    /// `CapacityChanged`; nothing has changed then.
    pub fn rekeyField(self: *Journal, tables: *Table.Registry, old_key: Atom, new_key: Atom, field_name: []const u8, before: []const u8, after: []const u8) Error!void {
        if (self.active) |active| if (active.key == old_key or active.key == new_key) return error.TransactionOpen;
        if (old_key == new_key) return;
        if (before.len != after.len) return error.SchemaChanged;
        var it = self.first;
        while (it) |item| : (it = item.next) {
            if (item.key == new_key) return error.Conflict;
            if (item.key != old_key) continue;
            try self.preflight(tables, item, .all, null);
            var record: usize = first_record;
            while (record < item.used) : (record += item.at(Record, record).size) {
                if (item.at(Record, record).kind != .row) continue;
                const table = tables.get(item.at(RowRecord, record).handle).?;
                const index = table.getSchema().fieldIndex(field_name) orelse return error.SchemaChanged;
                if (table.getSchema().fields[index].stride != before.len) return error.SchemaChanged;
            }
        }
        var open = self.open_blocks;
        while (open) |block| : (open = block.next_open) {
            if (block.key == old_key) block.key = new_key;
        }
        it = self.first;
        while (it) |item| : (it = item.next) {
            if (item.key != old_key) continue;
            item.key = new_key;
            var record: usize = first_record;
            while (record < item.used) : (record += item.at(Record, record).size) {
                if (item.at(Record, record).kind != .row) continue;
                const table = tables.get(item.at(RowRecord, record).handle).?;
                const index = table.getSchema().fieldIndex(field_name).?;
                var offset: usize = imageHeaderSize(table);
                for (table.getSchema().fields[0..index]) |field| offset += field.stride;
                for ([_]ImageSide{ .before, .after }) |side| {
                    const bytes = item.image(record, side)[offset..][0..before.len];
                    if (std.mem.eql(u8, bytes, before)) @memcpy(bytes, after);
                }
            }
        }
        self.revision +%= 1;
    }

    /// Explicit escape hatch after external schema/table replacement. Unlike
    /// cancel this does NOT restore any rows. Never use it for a normal gesture. Removes the
    /// open transaction's entry and tells the observer `discarded`. Fails with
    /// `NoTransaction` and `AdmissionMutationRejected`.
    pub fn abandon(self: *Journal) Error!void {
        const item = self.active orelse return error.NoTransaction;
        try self.rejectRelease(item);
        self.revision +%= 1;
        self.endActive(item, .discarded);
    }

    /// Hashes metadata and every readable log. Walks all retained bytes, so plans compare
    /// `revision` instead; this is for proving history unchanged in tests.
    pub fn contentHash(self: *const Journal) u64 {
        var hash = std.hash.Wyhash.init(0);
        var it = self.first;
        while (it) |item| : (it = item.next) {
            const info = item.metadata();
            hash.update(std.mem.asBytes(&info.sequence));
            hash.update(std.mem.asBytes(&info.key));
            hash.update(std.mem.asBytes(&info.label));
            hash.update(std.mem.asBytes(&info.bytes));
            hash.update(std.mem.asBytes(&info.rows));
            hash.update(std.mem.asBytes(&info.tables));
            hash.update(std.mem.asBytes(&info.state));
            if (item.block != null and self.logAvailable(item)) hash.update(item.log[first_record..item.used]);
        }
        return hash.final();
    }

    /// False once `item`'s scope is released: its block went with it and must not be read.
    /// An entry with no block has nothing to lose.
    fn logAvailable(self: *const Journal, item: *const Entry) bool {
        if (item.block == null) return true;
        return self.memory.scopeFor(item.scope) != null;
    }

    fn preflight(self: *const Journal, tables: *Table.Registry, item: *const Entry, selection: RestoreSelection, expected: ?ImageSide) Error!void {
        if (!self.logAvailable(item)) return error.StaleTable;
        // Table records precede their rows. No writes occur until ALL selected pass.
        switch (selection) {
            .all => {
                var offset: usize = first_record;
                while (offset < item.used) : (offset += item.at(Record, offset).size) {
                    switch (item.at(Record, offset).kind) {
                        .table => {
                            const record = item.at(TableRecord, offset);
                            try validateTable(tables.get(record.handle) orelse return error.StaleTable, record);
                        },
                        .row => try preflightRow(tables, item, offset, expected),
                        .before_free, .after_free, .index => {},
                    }
                }
            },
            .cycle_dirty => {
                var table_rel = item.dirty_tables_head;
                while (table_rel != 0) {
                    const record = item.at(TableRecord, table_rel);
                    try validateTable(tables.get(record.handle) orelse return error.StaleTable, record);
                    var row_rel = record.dirty_rows_head;
                    while (row_rel != 0) : (row_rel = item.at(RowRecord, row_rel).dirty_next) {
                        try preflightRow(tables, item, row_rel, expected);
                    }
                    table_rel = record.dirty_next_table;
                }
            },
        }
    }

    fn preflightRow(tables: *Table.Registry, item: *const Entry, offset: usize, expected: ?ImageSide) Error!void {
        const record = item.at(RowRecord, offset);
        const table = tables.get(record.handle) orelse return error.StaleTable;
        if (record.row >= table.rowCapacity()) return error.CapacityChanged;
        if (expected) |side| {
            if (!matches(table, record.row, item.image(offset, side))) return error.Conflict;
        }
    }

    fn restore(tables: *Table.Registry, item: *const Entry, selection: RestoreSelection, side: ImageSide) void {
        // Remove desired-dead rows first so a full table has room for revived IDs.
        const phases = [_]Liveness{ .dead, .live };
        switch (selection) {
            .all => {
                for (phases) |phase| {
                    var row_offset: usize = first_record;
                    while (row_offset < item.used) : (row_offset += item.at(Record, row_offset).size) {
                        if (item.at(Record, row_offset).kind == .row) restoreRow(tables, item, row_offset, side, phase);
                    }
                }
                var table_offset: usize = first_record;
                while (table_offset < item.used) : (table_offset += item.at(Record, table_offset).size) {
                    if (item.at(Record, table_offset).kind == .table) restoreTable(tables, item, table_offset, selection, side);
                }
            },
            .cycle_dirty => {
                var table_rel = item.dirty_tables_head;
                while (table_rel != 0) : (table_rel = item.at(TableRecord, table_rel).dirty_next_table) {
                    for (phases) |phase| {
                        var row_rel = item.at(TableRecord, table_rel).dirty_rows_head;
                        while (row_rel != 0) : (row_rel = item.at(RowRecord, row_rel).dirty_next) {
                            restoreRow(tables, item, row_rel, side, phase);
                        }
                    }
                    restoreTable(tables, item, table_rel, selection, side);
                }
            },
        }
    }

    fn restoreRow(tables: *Table.Registry, item: *const Entry, offset: usize, side: ImageSide, phase: Liveness) void {
        const record = item.at(RowRecord, offset);
        const row_image = item.image(offset, side);
        const liveness: Liveness = if (row_image[12] != 0) .live else .dead;
        if (liveness == phase) restoreImage(tables.get(record.handle).?, record.row, row_image);
    }

    /// Runs after the selection's rows are restored. Singleton reusable state follows
    /// its restored scalar liveness, and selections without journal allocation/free
    /// never changed reusable IDs, so only lifecycle selections merge free lists.
    fn restoreTable(tables: *Table.Registry, item: *const Entry, table_offset: usize, selection: RestoreSelection, side: ImageSide) void {
        const record = item.at(TableRecord, table_offset);
        const table = tables.get(record.handle).?;
        const lifecycle = switch (selection) {
            .all => record.before_free_rel != 0,
            .cycle_dirty => record.cycle_lifecycle,
        };
        if (lifecycle and !table.isSingleton()) restoreReusable(table, item, record, selection, side);
        table.touch();
    }

    fn restoreReusable(table: *Table, item: *const Entry, record: *const TableRecord, selection: RestoreSelection, side: ImageSide) void {
        // Remove only selected rows; all unrelated free entries retain order.
        var index: usize = 0;
        while (index < table.reusableRows().len) {
            const row = table.reusableRows().at(index);
            if (selectedRow(item, record.handle, row, selection)) {
                table.removeReusableAt(index);
            } else index += 1;
        }
        const snapshot_rel = switch (side) {
            .before => record.before_free_rel,
            .after => record.after_free_rel,
        };
        // A lifecycle admission always snapshots first, and commit adds the after side.
        std.debug.assert(snapshot_rel != 0);
        const desired = item.freeRows(snapshot_rel);
        const capacity = item.at(FreeRecord, snapshot_rel).capacity;
        // Insert each selected free row at its historical next surviving
        // neighbor. This is exact absent divergence, and merge-aware otherwise.
        for (desired, 0..) |row, i| {
            if (row >= table.rowCapacity() or table.isAllocated(row) or !selectedRow(item, record.handle, row, selection)) continue;
            var position = table.reusableRows().len;
            for (desired[i + 1 ..]) |next| {
                if (table.reusableRows().indexOf(next)) |found| {
                    position = found;
                    break;
                }
            }
            table.insertReusableAt(position, row);
        }
        // A snapshot can predate growth in the transaction. New rows are
        // retained, and their pre-allocation images return them to the prefix.
        var row = table.rowCapacity();
        while (row > capacity) {
            row -= 1;
            if (table.isAllocated(row) or !selectedRow(item, record.handle, row, selection)) continue;
            var position: usize = 0;
            while (position < table.reusableRows().len and table.reusableRows().at(position) > row) : (position += 1) {}
            table.insertReusableAt(position, row);
        }
        // External frees before a row's first touch can leave its unallocated
        // image absent from the snapshot. Such rows have no saved position;
        // append them without disturbing unrelated entries.
        switch (selection) {
            .all => {
                var offset: usize = first_record;
                while (offset < item.used) : (offset += item.at(Record, offset).size) {
                    if (item.at(Record, offset).kind != .row) continue;
                    const touched = item.at(RowRecord, offset);
                    if (std.meta.eql(touched.handle, record.handle)) appendAbsentReusable(table, touched.row);
                }
            },
            .cycle_dirty => {
                var row_rel = record.dirty_rows_head;
                while (row_rel != 0) : (row_rel = item.at(RowRecord, row_rel).dirty_next) {
                    appendAbsentReusable(table, item.at(RowRecord, row_rel).row);
                }
            },
        }
    }

    fn selectedRow(item: *const Entry, handle: Table.Handle, row: u32, selection: RestoreSelection) bool {
        const row_rel = item.findRow(handle, row) orelse return false;
        return switch (selection) {
            .all => true,
            .cycle_dirty => item.at(RowRecord, row_rel).dirty,
        };
    }

    /// Ends a preview cycle. Records, indexes, snapshots and first before-images
    /// stay for later cycles, cancel and undo; a later touch relinks its row.
    fn clearDirty(item: *Entry) void {
        var table_rel = item.dirty_tables_head;
        while (table_rel != 0) {
            const table_record = item.at(TableRecord, table_rel);
            var row_rel = table_record.dirty_rows_head;
            while (row_rel != 0) {
                const row_record = item.at(RowRecord, row_rel);
                row_rel = row_record.dirty_next;
                row_record.dirty = false;
                row_record.dirty_next = 0;
            }
            table_rel = table_record.dirty_next_table;
            table_record.dirty = false;
            table_record.cycle_lifecycle = false;
            table_record.dirty_rows_head = 0;
            table_record.dirty_next_table = 0;
        }
        item.dirty_tables_head = 0;
    }

    /// Admits `amount` more log bytes for the active entry. Every fallible step precedes
    /// the first eviction, so a refusal leaves all history as it was.
    fn reserve(self: *Journal, item: *Entry, amount: usize) Error!void {
        try self.checkRetention(amount);
        const needed = try addSize(item.used, amount);
        try self.ensureLog(item, needed);
        self.evictFor(amount);
    }

    /// An admission refuses to release an arena that predates it, and silently: the entry
    /// would lose its log. Call before the first change of anything that removes `item`.
    fn rejectRelease(self: *Journal, item: *const Entry) Error!void {
        if (item.block != null and self.logAvailable(item)) try self.memory.rejectInsideAdmission();
    }

    fn checkRetention(self: *Journal, amount: usize) Error!void {
        const limit = switch (self.retention) {
            .unbounded => return,
            .bytes => |bytes| bytes,
        };
        const active_size = if (self.active) |active| active.accountedBytes() else 0;
        if (amount > limit -| active_size) return error.BudgetExceeded;
        // Making room would evict, which releases arenas.
        if (self.used > limit -| amount) try self.memory.rejectInsideAdmission();
    }

    fn evictFor(self: *Journal, amount: usize) void {
        const limit = switch (self.retention) {
            .unbounded => return,
            .bytes => |bytes| bytes,
        };
        while (self.used > limit -| amount) {
            const oldest = self.first orelse return;
            if (oldest == self.active) return;
            // Evicting the head of a redo chain must not leave a redo gap.
            if (oldest.state == .undone) {
                self.removeUndone(oldest.key, .evicted);
            } else self.remove(oldest, .evicted);
        }
    }

    /// Grows in place when `item` is its block's newest, else publishes a copy in new space
    /// and leaves the old; a failure leaves the entry as it was. Small logs double as they
    /// move; a log past a shared block asks for what it needs, since its arena already maps
    /// half again that to grow into. A closing scope can only grow in place, and never starts
    /// a log, whatever space an open block has left.
    fn ensureLog(self: *Journal, item: *Entry, needed: usize) Error!void {
        if (needed <= item.log.len) return;
        const scope = self.memory.scopeFor(item.scope) orelse return error.StaleTable;
        if (item.block) |block| {
            if (growInBlock(block, item, needed)) return;
        }
        if (scope.state != .open) return error.ScopeClosing;
        // An aborted admission destroys arenas it saw created; this entry would dangle.
        try self.memory.rejectInsideAdmission();
        const doubled = item.log.len * 2;
        const request = @max(needed, initial_log_bytes, if (doubled <= shared_log_limit) doubled else 0);
        const destination = try self.blockWithSpace(scope, item, request);
        const start = destination.used;
        const log: []align(alignment) u8 = @alignCast(destination.bytes[start..][0..request]);
        destination.used = start + request;
        destination.live += 1;
        if (item.block != null) {
            @memcpy(log[0..item.used], item.log[0..item.used]);
            self.releaseLog(item);
        }
        item.block = destination;
        item.log = log;
    }

    fn growInBlock(block: *LogBlock, item: *Entry, needed: usize) bool {
        const start = @intFromPtr(item.log.ptr) - @intFromPtr(block.bytes.ptr);
        if (start + item.log.len != block.used) return false;
        const end = start + needed;
        if (end > block.bytes.len) {
            // A block its log alone fills can still extend into the arena's mapping.
            if (!block.arena.allocator().resize(block.bytes, end)) return false;
            block.bytes.len = end;
        }
        block.used = end;
        item.log = @alignCast(block.bytes[start..end]);
        return true;
    }

    /// A block of `item`'s scope and key with `request` free bytes. The caller takes the space
    /// with nothing fallible left; every failure here comes before a new block is linked.
    fn blockWithSpace(self: *Journal, scope: *Scope, item: *const Entry, request: usize) Error!*LogBlock {
        var full_block: ?*LogBlock = null;
        var it = self.open_blocks;
        while (it) |block| : (it = block.next_open) {
            if (block.key != item.key or !std.meta.eql(block.scope, item.scope)) continue;
            if (request <= block.bytes.len - block.used) return block;
            full_block = block;
            break;
        }
        const record = try self.takeBlockRecord();
        errdefer {
            record.next_open = self.free_blocks;
            self.free_blocks = record;
        }
        const arena = try scope.createArena();
        errdefer scope.releaseArena(arena);
        const allocator = arena.allocator();
        const shared = request <= shared_log_limit;
        const size = if (shared) block_request_bytes else request;
        var bytes = try allocator.alignedAlloc(u8, .fromByteUnits(alignment), size);
        if (shared) {
            // The rest of the mapping; the arena's bookkeeping may keep a few bytes.
            const whole = std.mem.alignBackward(usize, arena.reserved() - alignment, alignment);
            if (whole > bytes.len and allocator.resize(bytes, whole)) bytes.len = whole;
        }
        record.* = .{ .scope = item.scope, .key = item.key, .arena = arena, .bytes = bytes, .used = 0 };
        if (shared) {
            // Replaces the block too full for this log; a refusal above left it open.
            if (full_block) |block| self.closeBlock(block);
            record.open = true;
            record.next_open = self.open_blocks;
            if (self.open_blocks) |first| first.previous_open = record;
            self.open_blocks = record;
        }
        return record;
    }

    fn closeBlock(self: *Journal, block: *LogBlock) void {
        if (!block.open) return;
        block.open = false;
        if (block.previous_open) |previous| previous.next_open = block.next_open else self.open_blocks = block.next_open;
        if (block.next_open) |next| next.previous_open = block.previous_open;
        block.previous_open = null;
        block.next_open = null;
    }

    fn takeBlockRecord(self: *Journal) Error!*LogBlock {
        if (self.free_blocks) |record| {
            self.free_blocks = record.next_open;
            return record;
        }
        const allocator = self.nodes.allocator();
        return allocator.create(LogBlock);
    }

    /// A committed entry takes no more bytes, so the next one can start right after it.
    fn trimLog(item: *Entry) void {
        const block = item.block orelse return;
        const start = @intFromPtr(item.log.ptr) - @intFromPtr(block.bytes.ptr);
        if (start + item.log.len != block.used) return;
        block.used = start + item.used;
        item.log.len = item.used;
    }

    fn removeUndone(self: *Journal, key: Atom, kind: EventKind) void {
        var it = self.first;
        while (it) |item| {
            it = item.next;
            if (item.key == key and item.state == .undone) self.remove(item, kind);
        }
    }

    fn endActive(self: *Journal, item: *Entry, kind: EventKind) void {
        self.active = null;
        self.remove(item, kind);
    }

    /// Unlinks and returns the entry's pages. The node goes back to the free list.
    fn remove(self: *Journal, item: *Entry, kind: EventKind) void {
        const info = item.metadata();
        self.releaseLog(item);
        if (item.previous) |previous| previous.next = item.next else self.first = item.next;
        if (item.next) |next| next.previous = item.previous else self.last = item.previous;
        self.count -= 1;
        self.used -= info.bytes;
        self.revision +%= 1;
        item.next = self.free_nodes;
        self.free_nodes = item;
        self.emit(kind, info);
    }

    /// Leaves `item`'s block, returning its pages if it was the last entry there.
    fn releaseLog(self: *Journal, item: *Entry) void {
        const block = item.block orelse return;
        const start = @intFromPtr(item.log.ptr) - @intFromPtr(block.bytes.ptr);
        const newest = start + item.log.len == block.used;
        item.block = null;
        item.log = &.{};
        const scope = self.memory.scopeFor(block.scope);
        // A released scope took the bytes; only the record's count still means anything.
        if (newest and scope != null) block.used = start;
        block.live -= 1;
        if (block.live != 0) return;
        self.closeBlock(block);
        if (scope) |owner| owner.releaseArena(block.arena);
        block.next_open = self.free_blocks;
        self.free_blocks = block;
    }

    fn takeNode(self: *Journal) Error!*Entry {
        if (self.free_nodes) |node| {
            self.free_nodes = node.next;
            return node;
        }
        const allocator = self.nodes.allocator();
        return allocator.create(Entry);
    }

    fn append(self: *Journal, item: *Entry, size: usize) usize {
        const offset = item.used;
        @memset(item.log[offset .. offset + size], 0);
        item.used += size;
        self.used += size;
        return offset;
    }

    /// Appends the table's current reusable IDs; the caller reserved
    /// freeSnapshotSize(table) bytes. Returns the record's offset.
    fn appendFreeSnapshot(self: *Journal, item: *Entry, kind: RecordKind, handle: Table.Handle, table: *const Table) usize {
        const size = freeSnapshotSize(table) catch unreachable;
        const reusable = table.reusableRows();
        const offset = self.append(item, size);
        item.at(FreeRecord, offset).* = .{
            .header = .{ .size = size, .kind = kind },
            .handle = handle,
            .capacity = table.rowCapacity(),
            .free_count = @intCast(reusable.len),
        };
        reusable.copyTo(item.freeRows(offset));
        return offset;
    }

    /// Appends a larger zeroed index of `size` bytes and reinserts every table and
    /// row record. The replaced index stays inert, accounted bytes until removal.
    fn replaceIndex(self: *Journal, item: *Entry, capacity: usize, size: usize) void {
        const offset = self.append(item, size);
        item.at(IndexRecord, offset).* = .{ .header = .{ .size = size, .kind = .index }, .capacity = capacity };
        item.index_rel = offset;
        var record: usize = first_record;
        while (record < offset) : (record += item.at(Record, record).size) {
            switch (item.at(Record, record).kind) {
                .table, .row => item.indexInsert(record),
                .before_free, .after_free, .index => {},
            }
        }
    }

    /// Capacity of the replacement index that keeps at most half the slots occupied
    /// after `new_keys` insertions, or null when the current index suffices.
    fn grownIndexCapacity(item: *const Entry, new_keys: usize) Error!?usize {
        if (new_keys == 0) return null;
        const keys = @as(usize, item.tables) + item.rows + new_keys;
        var capacity: usize = if (item.indexSlots()) |slots| slots.len else 0;
        if (keys <= capacity / 2) return null;
        if (capacity == 0) capacity = initial_index_capacity;
        while (keys > capacity / 2) capacity = std.math.mul(usize, capacity, 2) catch return error.BudgetExceeded;
        return capacity;
    }

    fn emit(self: *const Journal, kind: EventKind, info: Metadata) void {
        if (self.observer) |observer| observer.notify(observer.context, .{ .kind = kind, .entry = info });
    }

    fn entryAt(self: *const Journal, index: usize) ?*Entry {
        var it = self.first;
        var i: usize = 0;
        while (it) |item| : (it = item.next) {
            if (i == index) return item;
            i += 1;
        }
        return null;
    }

    fn historyEntry(self: *const Journal, key: Atom, state: State) ?*Entry {
        switch (state) {
            .undone => {
                var it = self.first;
                while (it) |item| : (it = item.next) {
                    if (item.key == key and item.state == .undone) return item;
                }
            },
            else => {
                var it = self.last;
                while (it) |item| : (it = item.previous) {
                    if (item.key == key and item.state == state) return item;
                }
            },
        }
        return null;
    }
};

fn padded(size: usize) usize {
    return std.mem.alignForward(usize, size, alignment);
}
/// Overflow is a budget failure, detected before any mutation.
fn addSize(a: usize, b: usize) Error!usize {
    return std.math.add(usize, a, b) catch return error.BudgetExceeded;
}
fn recordSize(header_size: usize, count: usize, item_size: usize) Error!usize {
    const items = std.math.mul(usize, count, item_size) catch return error.BudgetExceeded;
    const unpadded = try addSize(header_size, items);
    if (unpadded > std.math.maxInt(usize) - (alignment - 1)) return error.BudgetExceeded;
    return padded(unpadded);
}
fn freeSnapshotSize(table: *const Table) Error!usize {
    return recordSize(@sizeOf(FreeRecord), table.reusableRows().len, @sizeOf(u32));
}
fn hashKey(key: IndexKey) usize {
    // Hash explicit integers, never struct padding.
    const words = [4]u32{ @intFromEnum(key.kind), key.handle.index, key.handle.generation, key.row };
    return @truncate(std.hash.Wyhash.hash(0, std.mem.asBytes(&words)));
}
fn appendAbsentReusable(table: *Table, row: u32) void {
    if (table.isAllocated(row) or table.reusableRows().indexOf(row) != null) return;
    table.insertReusableAt(table.reusableRows().len, row);
}
fn fingerprint(table: *const Table) Error!u64 {
    var hash = std.hash.Wyhash.init(0);
    const schema = table.getSchema();
    for (schema.fields) |field| {
        if (field.contains_pointer) return error.PointerField;
        hash.update(std.mem.asBytes(&field.name.len));
        hash.update(field.name);
        hash.update(std.mem.asBytes(&field.size));
        hash.update(std.mem.asBytes(&field.stride));
        hash.update(std.mem.asBytes(&field.column_index));
        hash.update(std.mem.asBytes(&field.bit));
        hash.update(std.mem.asBytes(&field.semantic_type));
        const field_type: u8 = if (field.field_type) |t| @intCast(@intFromEnum(t)) else 255;
        hash.update(&.{field_type});
    }
    return hash.final();
}
fn validateTable(table: *const Table, record: *const TableRecord) Error!void {
    if (try fingerprint(table) != record.schema) return error.SchemaChanged;
    if (table.rowCapacity() < record.capacity) return error.CapacityChanged;
}
/// A row image starts with the table's mask words (little-endian), then the u32
/// generation and the u8 allocated flag, then every field's bytes in schema order.
fn imageHeaderSize(table: *const Table) usize {
    return @as(usize, table.maskWords()) * 8 + 5;
}
fn rowImageSize(table: *const Table) usize {
    var size: usize = imageHeaderSize(table);
    for (table.getSchema().fields) |field| size += field.stride;
    return size;
}
fn imageMask(table: *const Table, bytes: []const u8) Mask {
    var mask: Mask = .empty;
    for (mask.words[0..table.maskWords()], 0..) |*word, index| word.* = std.mem.readInt(u64, bytes[index * 8 ..][0..8], .little);
    return mask;
}
fn imageGeneration(table: *const Table, bytes: []const u8) u32 {
    const offset = @as(usize, table.maskWords()) * 8;
    return std.mem.readInt(u32, bytes[offset..][0..4], .little);
}
fn imageAllocated(table: *const Table, bytes: []const u8) bool {
    return bytes[@as(usize, table.maskWords()) * 8 + 4] != 0;
}
fn capture(table: *const Table, row: u32, bytes: []u8) void {
    // Dead logical IDs have no physical payload: their canonical image is zero
    // except for the ID generation. Never capture an unrelated dense slot.
    @memset(bytes, 0);
    const mask = table.rowMask(row);
    const words = table.maskWords();
    for (mask.words[0..words], 0..) |word, index| std.mem.writeInt(u64, bytes[index * 8 ..][0..8], word, .little);
    std.mem.writeInt(u32, bytes[@as(usize, words) * 8 ..][0..4], table.rowGeneration(row), .little);
    bytes[@as(usize, words) * 8 + 4] = @intFromBool(table.isAllocated(row));
    if (!table.isAllocated(row)) return;
    var offset: usize = imageHeaderSize(table);
    for (table.getSchema().fields, 0..) |field, index| {
        @memcpy(bytes[offset..][0..field.stride], table.rowFieldBytes(row, index));
        offset += field.stride;
    }
}
fn matches(table: *const Table, row: u32, bytes: []const u8) bool {
    if (!table.rowMask(row).eql(imageMask(table, bytes)) or
        table.rowGeneration(row) != imageGeneration(table, bytes) or
        table.isAllocated(row) != imageAllocated(table, bytes)) return false;
    if (!table.isAllocated(row)) return true;
    var offset: usize = imageHeaderSize(table);
    for (table.getSchema().fields, 0..) |field, index| {
        if (!std.mem.eql(u8, bytes[offset..][0..field.stride], table.rowFieldBytes(row, index))) return false;
        offset += field.stride;
    }
    return true;
}
fn restoreImage(table: *Table, row: u32, bytes: []const u8) void {
    table.restoreRowState(row, imageGeneration(table, bytes), imageMask(table, bytes), imageAllocated(table, bytes));
    if (!table.isAllocated(row)) return;
    var offset: usize = imageHeaderSize(table);
    for (table.getSchema().fields, 0..) |field, index| {
        @memcpy(table.rowFieldBytes(row, index), bytes[offset..][0..field.stride]);
        offset += field.stride;
    }
}

const testing = std.testing;
const key_a = Atom.from("doc_a");
const key_b = Atom.from("doc_b");
const test_label = Atom.from("edit");
const test_schema: Table.Schema = .{ .fields = &.{
    .{ .name = "value", .size = 4, .stride = 4, .column_index = 0, .bit = 0, .field_type = .i32 },
    .{ .name = "bytes", .size = 7, .stride = 7, .column_index = 1, .bit = 1 },
    .{ .name = "tag", .size = 0, .stride = 0, .column_index = 2, .bit = 2, .field_type = .tag },
} };
test "absolute previews retain one before-image and Save As retains keyed undo" {
    var f: Fixture = undefined;
    try f.init(64 * 1024, 4);
    defer f.deinit();
    const table = f.tables.get(f.handles[0]).?;
    const row = try table.alloc();
    try table.writeFieldSingle(i32, row, "value", 1);
    try f.journal.begin(f.scope, key_a, test_label);
    for (0..5) |i| {
        if (i != 0) try f.journal.resetPreview(&f.tables);
        try testing.expectEqual(@as(i32, 1), table.getField(i32, row, "value").?.*);
        try f.journal.touch(&f.tables, f.handles[0], row.row);
        try table.writeFieldSingle(i32, row, "value", @as(i32, @intCast(i)) + 2);
    }
    try f.journal.commit(&f.tables);
    try testing.expectEqual(@as(usize, 1), f.journal.entryCount());
    _ = try f.journal.undo(&f.tables, key_a);
    try testing.expectEqual(@as(i32, 1), table.getField(i32, row, "value").?.*);
    _ = try f.journal.redo(&f.tables, key_a);
    try testing.expectEqual(@as(i32, 6), table.getField(i32, row, "value").?.*);
    const old: i32 = 6;
    const new: i32 = 9;
    try f.journal.rekeyField(&f.tables, key_a, key_b, "value", std.mem.asBytes(&old), std.mem.asBytes(&new));
    try table.writeFieldSingle(i32, row, "value", new);
    _ = try f.journal.undo(&f.tables, key_b);
    try testing.expectEqual(@as(i32, 1), table.getField(i32, row, "value").?.*);
    _ = try f.journal.redo(&f.tables, key_b);
    try testing.expectEqual(new, table.getField(i32, row, "value").?.*);
    try testing.expectError(error.NoHistory, f.journal.undo(&f.tables, key_a));
}

test "table_journal middle deletion undo redo preserves an untouched moved peer across growth and ID reuse" {
    var f: Fixture = undefined;
    try f.init(128 * 1024, 4);
    defer f.deinit();
    const identity = f.handles[0];
    const table = f.tables.get(identity).?;
    var rows: [4]Table.RowHandle = undefined;
    for (&rows, 0..) |*row, i| {
        row.* = try table.alloc();
        try table.writeFieldSingle(i32, row.*, "value", @intCast(11 + i));
    }
    try f.journal.begin(f.scope, key_a, test_label);
    try f.journal.recordFree(&f.tables, identity, rows[1]);
    try f.journal.commit(&f.tables);
    try testing.expect(table.valid(rows[3]));
    var dead_image_storage: [Mask.max_words * 8 + 5 + 11]u8 = undefined;
    const dead_image = dead_image_storage[0..rowImageSize(table)];
    capture(table, rows[1].row, dead_image);
    try testing.expect(std.mem.allEqual(u8, dead_image[imageHeaderSize(table)..], 0));
    try table.writeFieldSingle(i32, rows[3], "value", 99); // Unrelated logical edit, despite physical relocation.
    try testing.expect(matches(table, rows[1].row, dead_image));
    _ = try f.journal.undo(&f.tables, key_a);
    try testing.expect(table.valid(rows[1]));
    try testing.expectEqual(@as(i32, 12), table.getField(i32, rows[1], "value").?.*);
    try testing.expectEqual(@as(i32, 99), table.getField(i32, rows[3], "value").?.*);
    _ = try f.journal.redo(&f.tables, key_a);
    try testing.expect(!table.valid(rows[1]));
    try testing.expect(table.valid(rows[3]));
    try f.tables.grow(identity, 8);
    try f.journal.begin(f.scope, key_b, test_label);
    const added = try f.journal.recordAlloc(&f.tables, identity);
    try testing.expect(added.row >= 4); // The retained deletion image quarantines ID 1.
    try table.writeFieldSingle(i32, added, "value", 55);
    try f.journal.recordFree(&f.tables, identity, rows[0]);
    const reused = try f.journal.recordAllocAt(&f.tables, identity, table.reusableRows().len - 1);
    try testing.expectEqual(rows[0].row, reused.row);
    try testing.expect(reused.generation != rows[0].generation);
    try table.writeFieldSingle(i32, reused, "value", 77);
    try f.journal.commit(&f.tables);
    _ = try f.journal.undo(&f.tables, key_b);
    try testing.expect(table.valid(rows[0]));
    try testing.expect(!table.valid(added));
    try testing.expectEqual(@as(i32, 11), table.getField(i32, rows[0], "value").?.*);
    try testing.expectEqual(@as(i32, 99), table.getField(i32, rows[3], "value").?.*);
    _ = try f.journal.redo(&f.tables, key_b);
    try testing.expect(table.valid(reused));
    try testing.expect(!table.valid(rows[0]));
    try testing.expectEqual(@as(i32, 77), table.getField(i32, reused, "value").?.*);
    try testing.expectEqual(@as(i32, 99), table.getField(i32, rows[3], "value").?.*);
    try expectFreeListValid(table);
}

test "table_journal singleton scalar liveness survives allocation and free undo redo" {
    var f: Fixture = undefined;
    try f.init(64 * 1024, 4);
    defer f.deinit();
    const handle = try f.tables.createSingleton(&test_schema, Atom.from("scalar_journal"), .durable);
    const table = f.tables.get(handle).?;
    try f.journal.begin(f.scope, key_a, test_label);
    const row = try f.journal.recordAlloc(&f.tables, handle);
    try table.writeFieldSingle(i32, row, "value", 7);
    try f.journal.commit(&f.tables);
    _ = try f.journal.undo(&f.tables, key_a);
    try testing.expectEqual(@as(u32, 0), table.count());
    try table.reusableRows().expectEqual(&.{0});
    _ = try f.journal.redo(&f.tables, key_a);
    try testing.expect(table.valid(row));
    try testing.expectEqual(@as(i32, 7), table.getField(i32, row, "value").?.*);
    try f.journal.begin(f.scope, key_a, test_label);
    try f.journal.recordFree(&f.tables, handle, row);
    try f.journal.commit(&f.tables);
    _ = try f.journal.undo(&f.tables, key_a);
    try testing.expect(table.valid(row));
    _ = try f.journal.redo(&f.tables, key_a);
    try testing.expect(!table.valid(row));
    try testing.expectEqual(@as(u32, 0), table.count());
    try testing.expect(table.isSingleton());
}

const Fixture = struct {
    memory: memory_mod.Memory = undefined,
    tables: Table.Registry = undefined,
    journal: Journal = undefined,
    handles: [3]Table.Handle = undefined,
    scope: Scope.Id = undefined,

    fn init(self: *Fixture, budget: usize, capacity: u32) !void {
        self.memory.init(testing.allocator);
        errdefer self.memory.deinit();
        try self.tables.init(&self.memory, 8);
        errdefer self.tables.deinit();
        inline for (.{ "first", "second", "third" }, 0..) |name, i| {
            self.handles[i] = try self.tables.create(&test_schema, capacity, Atom.from(name), .durable);
        }
        self.scope = try self.memory.openScope(Atom.from("journal_test"));
        self.journal = try Journal.init(&self.memory, try self.nodeArena(), .{ .bytes = budget });
    }
    /// Apart from `scope`, whose totals the tests read as the entries' alone.
    fn nodeArena(self: *Fixture) !*Arena {
        const nodes_scope = try self.memory.resolvedPrivateScope(Atom.from("test.journal_nodes"));
        return nodes_scope.createArena();
    }

    fn deinit(self: *Fixture) void {
        self.tables.deinit();
        self.memory.deinit();
    }
};

// Full snapshots are test oracles only; production logs copy touched row bytes.
fn snapshot(tables: *Table.Registry, handles: []const Table.Handle) ![]u8 {
    var bytes: std.ArrayListUnmanaged(u8) = .empty;
    errdefer bytes.deinit(testing.allocator);
    for (handles) |handle| {
        const table = tables.get(handle).?;
        const capacity = table.rowCapacity();
        try bytes.appendSlice(testing.allocator, std.mem.asBytes(&capacity));
        for (0..capacity) |row| {
            const mask = table.rowMask(@intCast(row));
            try bytes.appendSlice(testing.allocator, std.mem.sliceAsBytes(&mask.words));
        }
        for (0..table.generationCount()) |row| {
            const generation = table.rowGeneration(@intCast(row));
            try bytes.appendSlice(testing.allocator, std.mem.asBytes(&generation));
        }
        for (0..capacity) |row| {
            const allocated = table.isAllocated(@intCast(row));
            try bytes.appendSlice(testing.allocator, std.mem.asBytes(&allocated));
        }
        const free_count = table.reusableRows().len;
        try bytes.appendSlice(testing.allocator, std.mem.asBytes(&free_count));
        for (0..table.reusableRows().len) |i| {
            const row = table.reusableRows().at(i);
            try bytes.appendSlice(testing.allocator, std.mem.asBytes(&row));
        }
        for (table.getSchema().fields, 0..) |_, field_index| {
            for (0..capacity) |row| {
                if (table.isAllocated(@intCast(row))) {
                    try bytes.appendSlice(testing.allocator, table.rowFieldBytes(@intCast(row), field_index));
                } else try bytes.appendNTimes(testing.allocator, 0, table.getSchema().fields[field_index].stride);
            }
        }
    }
    return bytes.toOwnedSlice(testing.allocator);
}
fn expectSnapshot(expected: []const u8, tables: *Table.Registry, handles: []const Table.Handle) !void {
    const actual = try snapshot(tables, handles);
    defer testing.allocator.free(actual);
    try testing.expectEqualSlices(u8, expected, actual);
}
fn expectFreeListValid(table: *const Table) !void {
    var count: usize = 0;
    for (0..table.rowCapacity()) |row| {
        const allocated = table.isAllocated(@intCast(row));
        var occurrences: usize = 0;
        for (0..table.reusableRows().len) |i| {
            if (table.reusableRows().at(i) == row) occurrences += 1;
        }
        try testing.expectEqual(@as(usize, if (allocated) 0 else 1), occurrences);
        if (!allocated) count += 1;
    }
    try testing.expectEqual(count, table.reusableRows().len);
}
// Test-only views of journal bookkeeping.
fn countRecords(journal: *const Journal, entry_index: usize, kind: RecordKind) usize {
    const item = journal.entryAt(entry_index).?;
    var count: usize = 0;
    var offset: usize = first_record;
    while (offset < item.used) : (offset += item.at(Record, offset).size) {
        if (item.at(Record, offset).kind == kind) count += 1;
    }
    return count;
}
fn rowDirty(journal: *const Journal, handle: Table.Handle, row: u32) bool {
    const item = journal.active.?;
    const row_rel = item.findRow(handle, row) orelse return false;
    return item.at(RowRecord, row_rel).dirty;
}
fn dirtyRowCount(journal: *const Journal) usize {
    const item = journal.active.?;
    var count: usize = 0;
    var table_rel = item.dirty_tables_head;
    while (table_rel != 0) : (table_rel = item.at(TableRecord, table_rel).dirty_next_table) {
        var row_rel = item.at(TableRecord, table_rel).dirty_rows_head;
        while (row_rel != 0) : (row_rel = item.at(RowRecord, row_rel).dirty_next) count += 1;
    }
    return count;
}
fn randomEdits(f: *Fixture, random: std.Random, steps: usize) !void {
    for (0..steps) |_| {
        const handle = f.handles[random.uintLessThan(usize, f.handles.len)];
        const table = f.tables.get(handle).?;
        var row = random.uintLessThan(u32, table.rowCapacity());
        switch (random.uintLessThan(u32, 3)) {
            0 => if (table.reusableRows().len != 0) {
                if (f.journal.recordAlloc(&f.tables, handle)) |allocated| {
                    row = allocated.row;
                } else |err| {
                    if (err != error.TableFull) return err;
                    try f.journal.touch(&f.tables, handle, row);
                }
            } else try f.journal.touch(&f.tables, handle, row),
            1 => {
                if (table.isAllocated(row)) {
                    try f.journal.recordFree(&f.tables, handle, .{ .row = row, .generation = table.rowGeneration(row) });
                } else try f.journal.touch(&f.tables, handle, row);
            },
            else => try f.journal.touch(&f.tables, handle, row),
        }
        // Include absent fields, tags, canonical dead rows and repeated touch calls.
        try f.journal.touch(&f.tables, handle, row);
        if (table.isAllocated(row)) {
            table.setMask(row, .{ .words = .{ random.uintLessThan(u64, 8), 0, 0, 0 } });
            for (table.getSchema().fields, 0..) |_, field_index| random.bytes(table.rowFieldBytes(row, field_index));
        }
        table.touch();
    }
}

test "table_journal randomized multi-table lifecycle commit cancel undo redo byte equality" {
    var f: Fixture = undefined;
    try f.init(2 * 1024 * 1024, 24);
    defer f.deinit();
    var prng = std.Random.DefaultPrng.init(0x29f9479a);
    const random = prng.random();
    var states: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (states.items) |state| testing.allocator.free(state);
        states.deinit(testing.allocator);
    }
    try states.append(testing.allocator, try snapshot(&f.tables, &f.handles));
    for (0..120) |iteration| {
        try f.journal.begin(f.scope, key_a, test_label);
        try randomEdits(&f, random, 1 + random.uintLessThan(usize, 30));
        if (iteration % 4 == 0) {
            try f.journal.cancel(&f.tables);
            try expectSnapshot(states.items[states.items.len - 1], &f.tables, &f.handles);
        } else {
            try f.journal.commit(&f.tables);
            try states.append(testing.allocator, try snapshot(&f.tables, &f.handles));
        }
        for (f.handles) |handle| try expectFreeListValid(f.tables.get(handle).?);
    }
    try testing.expectEqual(states.items.len - 1, f.journal.entryCount());
    var i = states.items.len - 1;
    while (i > 0) {
        i -= 1;
        _ = try f.journal.undo(&f.tables, key_a);
        try expectSnapshot(states.items[i], &f.tables, &f.handles);
    }
    try testing.expectError(error.NoHistory, f.journal.undo(&f.tables, key_a));
    for (states.items[1..]) |state| {
        _ = try f.journal.redo(&f.tables, key_a);
        try expectSnapshot(state, &f.tables, &f.handles);
    }
    try testing.expectError(error.NoHistory, f.journal.redo(&f.tables, key_a));
}

test "table_journal touch once and transaction guards" {
    var f: Fixture = undefined;
    try f.init(4096, 8);
    defer f.deinit();
    const handle = f.handles[0];
    const table = f.tables.get(handle).?;
    const original = try snapshot(&f.tables, &f.handles);
    defer testing.allocator.free(original);
    try testing.expectError(error.NoTransaction, f.journal.touch(&f.tables, handle, 0));
    try testing.expectError(error.NoTransaction, f.journal.recordAlloc(&f.tables, handle));
    try testing.expectError(error.NoTransaction, f.journal.commit(&f.tables));
    try testing.expectError(error.NoTransaction, f.journal.cancel(&f.tables));
    try testing.expectError(error.NoTransaction, f.journal.abandon());
    try f.journal.begin(f.scope, key_a, test_label);
    try testing.expectError(error.TransactionOpen, f.journal.begin(f.scope, key_b, test_label));
    try testing.expectError(error.TransactionOpen, f.journal.undo(&f.tables, key_a));
    try testing.expectError(error.TransactionOpen, f.journal.redo(&f.tables, key_b));
    try testing.expectError(error.TransactionOpen, f.journal.clear(key_a));
    const row = try f.journal.recordAlloc(&f.tables, handle);
    const bytes = f.journal.bytesUsed();
    for (0..1000) |i| {
        try f.journal.touch(&f.tables, handle, row.row);
        try table.writeFieldSingle(i32, row, "value", @intCast(i));
    }
    try testing.expectEqual(bytes, f.journal.bytesUsed());
    try testing.expectEqual(@as(u32, 1), f.journal.entry(0).?.rows);
    try testing.expectEqual(handle, f.journal.entryTable(0, 0).?);
    try testing.expectEqual(@as(?Table.Handle, null), f.journal.entryTable(0, 1));
    try f.journal.cancel(&f.tables);
    try expectSnapshot(original, &f.tables, &f.handles);
    try testing.expect(table.revision > 1000);
    try f.journal.begin(f.scope, key_a, test_label);
    try f.journal.commit(&f.tables);
    try testing.expectEqual(@as(usize, 0), f.journal.entryCount());
}

test "table_journal repeated value touches after preview reset retain gesture origin" {
    var f: Fixture = undefined;
    try f.init(8192, 8);
    defer f.deinit();
    var rows: [2]Table.RowHandle = undefined;
    for (f.handles[0..2], &rows, 0..) |handle, *row, i| {
        const table = f.tables.get(handle).?;
        row.* = try table.alloc();
        try table.writeFieldSingle(i32, row.*, "value", @intCast(10 + i));
    }
    const origin = try snapshot(&f.tables, &f.handles);
    defer testing.allocator.free(origin);
    try f.journal.begin(f.scope, key_a, test_label);
    // Alternate tables so every reset also has a clean table whose revision holds.
    for (0..6) |cycle| {
        const edited = cycle % 2;
        const table = f.tables.get(f.handles[edited]).?;
        const clean = f.tables.get(f.handles[1 - edited]).?;
        try f.journal.touch(&f.tables, f.handles[edited], rows[edited].row);
        try table.writeFieldSingle(i32, rows[edited], "value", @intCast(20 + cycle));
        try testing.expect(rowDirty(&f.journal, f.handles[edited], rows[edited].row));
        const clean_revision = clean.revision;
        try f.journal.resetPreview(&f.tables);
        try expectSnapshot(origin, &f.tables, &f.handles);
        try testing.expectEqual(clean_revision, clean.revision);
        try testing.expectEqual(@as(usize, 0), dirtyRowCount(&f.journal));
        // A reset without touches does no row work.
        const revision = table.revision;
        try f.journal.resetPreview(&f.tables);
        try testing.expectEqual(revision, table.revision);
    }
    try testing.expectEqual(@as(u32, 2), f.journal.entry(0).?.rows);
    const table = f.tables.get(f.handles[0]).?;
    try f.journal.touch(&f.tables, f.handles[0], rows[0].row);
    try table.writeFieldSingle(i32, rows[0], "value", 30);
    try f.journal.commit(&f.tables);
    _ = try f.journal.undo(&f.tables, key_a);
    try expectSnapshot(origin, &f.tables, &f.handles);
    _ = try f.journal.redo(&f.tables, key_a);
    try testing.expectEqual(@as(i32, 30), table.getRow(rows[0], struct { value: *i32 }).?.value.*);
    try testing.expectEqual(@as(i32, 11), f.tables.get(f.handles[1]).?.getRow(rows[1], struct { value: *i32 }).?.value.*);
}

test "table_journal value-only transactions never snapshot or reorder reusable IDs" {
    var f: Fixture = undefined;
    try f.init(64 * 1024, 4096);
    defer f.deinit();
    const handle = f.handles[0];
    const table = f.tables.get(handle).?;
    var rows: [8]Table.RowHandle = undefined;
    for (&rows, 0..) |*row, i| {
        row.* = try table.alloc();
        try table.writeFieldSingle(i32, row.*, "value", @intCast(i));
    }
    // A non-monotonic reusable order that no merge could rebuild from scratch.
    for ([_]usize{ 5, 1, 3 }) |i| table.free(rows[i]);
    const origin = try snapshot(&f.tables, &f.handles);
    defer testing.allocator.free(origin);
    for ([_]bool{ false, true }) |commit_and_undo| {
        try f.journal.begin(f.scope, key_a, test_label);
        for (0..3) |cycle| {
            for ([_]usize{ 0, 2, 4 }) |i| {
                try f.journal.touch(&f.tables, handle, rows[i].row);
                try table.writeFieldSingle(i32, rows[i], "value", @intCast(100 * cycle + i));
            }
            // Touching a dead row records its canonical image without lifecycle work.
            try f.journal.touch(&f.tables, handle, rows[1].row);
            try f.journal.resetPreview(&f.tables);
            try expectSnapshot(origin, &f.tables, &f.handles);
        }
        try f.journal.touch(&f.tables, handle, rows[6].row);
        try table.writeFieldSingle(i32, rows[6], "value", 66);
        try testing.expectEqual(@as(usize, 0), countRecords(&f.journal, 0, .before_free));
        if (commit_and_undo) {
            try f.journal.commit(&f.tables);
            try testing.expectEqual(@as(usize, 0), countRecords(&f.journal, 0, .after_free));
            const committed = try snapshot(&f.tables, &f.handles);
            defer testing.allocator.free(committed);
            _ = try f.journal.undo(&f.tables, key_a);
            try expectSnapshot(origin, &f.tables, &f.handles);
            _ = try f.journal.redo(&f.tables, key_a);
            try expectSnapshot(committed, &f.tables, &f.handles);
        } else {
            try f.journal.cancel(&f.tables);
            try expectSnapshot(origin, &f.tables, &f.handles);
        }
    }
}

test "table_journal value edits then lifecycle changes snapshot reusable IDs once" {
    var f: Fixture = undefined;
    try f.init(16 * 1024, 8);
    defer f.deinit();
    const handle = f.handles[0];
    const table = f.tables.get(handle).?;
    var rows: [4]Table.RowHandle = undefined;
    for (&rows, 0..) |*row, i| {
        row.* = try table.alloc();
        try table.writeFieldSingle(i32, row.*, "value", @intCast(i));
    }
    table.free(rows[1]);
    const origin = try snapshot(&f.tables, &f.handles);
    defer testing.allocator.free(origin);
    try f.journal.begin(f.scope, key_a, test_label);
    try f.journal.touch(&f.tables, handle, rows[2].row);
    try table.writeFieldSingle(i32, rows[2], "value", 20);
    try f.journal.resetPreview(&f.tables);
    try expectSnapshot(origin, &f.tables, &f.handles);
    try testing.expectEqual(@as(usize, 0), countRecords(&f.journal, 0, .before_free));
    // The value-edited row is freed, and the head of the reusable list is taken.
    for (0..2) |_| {
        try f.journal.touch(&f.tables, handle, rows[2].row);
        try table.writeFieldSingle(i32, rows[2], "value", 21);
        try f.journal.recordFree(&f.tables, handle, rows[2]);
        const added = try f.journal.recordAllocAt(&f.tables, handle, 0);
        try table.writeFieldSingle(i32, added, "value", 40);
        try testing.expectEqual(@as(usize, 1), countRecords(&f.journal, 0, .before_free));
        try f.journal.resetPreview(&f.tables);
        try expectSnapshot(origin, &f.tables, &f.handles);
    }
    try f.journal.recordFree(&f.tables, handle, rows[3]);
    const reused = try f.journal.recordAlloc(&f.tables, handle);
    try testing.expectEqual(rows[3].row, reused.row);
    try testing.expect(reused.generation != rows[3].generation);
    try table.writeFieldSingle(i32, reused, "value", 33);
    try f.journal.commit(&f.tables);
    try testing.expectEqual(@as(usize, 1), countRecords(&f.journal, 0, .before_free));
    try testing.expectEqual(@as(usize, 1), countRecords(&f.journal, 0, .after_free));
    const committed = try snapshot(&f.tables, &f.handles);
    defer testing.allocator.free(committed);
    _ = try f.journal.undo(&f.tables, key_a);
    try expectSnapshot(origin, &f.tables, &f.handles);
    _ = try f.journal.redo(&f.tables, key_a);
    try expectSnapshot(committed, &f.tables, &f.handles);
    try expectFreeListValid(table);
}

test "table_journal randomized preview cycles restore the origin before exact history" {
    var f: Fixture = undefined;
    try f.init(2 * 1024 * 1024, 24);
    defer f.deinit();
    var prng = std.Random.DefaultPrng.init(0x7e57ab1e);
    const random = prng.random();
    var states: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (states.items) |state| testing.allocator.free(state);
        states.deinit(testing.allocator);
    }
    try states.append(testing.allocator, try snapshot(&f.tables, &f.handles));
    for (0..60) |iteration| {
        const origin = states.items[states.items.len - 1];
        try f.journal.begin(f.scope, key_a, test_label);
        // Cycles mix value edits, dead-row touches, allocations and frees on rows
        // that earlier cycles may already have recorded.
        for (0..1 + random.uintLessThan(usize, 4)) |_| {
            try randomEdits(&f, random, 1 + random.uintLessThan(usize, 12));
            try f.journal.resetPreview(&f.tables);
            try expectSnapshot(origin, &f.tables, &f.handles);
        }
        try randomEdits(&f, random, 1 + random.uintLessThan(usize, 12));
        if (iteration % 4 == 0) {
            try f.journal.cancel(&f.tables);
            try expectSnapshot(origin, &f.tables, &f.handles);
        } else {
            try f.journal.commit(&f.tables);
            try states.append(testing.allocator, try snapshot(&f.tables, &f.handles));
        }
        for (f.handles) |handle| try expectFreeListValid(f.tables.get(handle).?);
    }
    var i = states.items.len - 1;
    while (i > 0) {
        i -= 1;
        _ = try f.journal.undo(&f.tables, key_a);
        try expectSnapshot(states.items[i], &f.tables, &f.handles);
    }
    for (states.items[1..]) |state| {
        _ = try f.journal.redo(&f.tables, key_a);
        try expectSnapshot(state, &f.tables, &f.handles);
    }
}

test "table_journal eviction and index growth keep dirty rows and relative lookups" {
    for ([_]bool{ false, true }) |commit_and_undo| {
        var f: Fixture = undefined;
        try f.init(4096, 32);
        defer f.deinit();
        var events: Events = .{};
        f.journal.rebind(events.observer());
        const handle = f.handles[0];
        const table = f.tables.get(handle).?;
        var rows: [12]Table.RowHandle = undefined;
        for (&rows, 0..) |*row, i| {
            row.* = try table.alloc();
            try table.writeFieldSingle(i32, row.*, "value", @intCast(i));
        }
        // Old history fills the budget, so the gesture's touches must evict it.
        const old_row = try f.tables.get(f.handles[1]).?.alloc();
        while (f.journal.bytesUsed() + 512 < 4096) {
            try f.journal.begin(f.scope, key_b, test_label);
            try f.journal.touch(&f.tables, f.handles[1], old_row.row);
            try f.journal.commit(&f.tables);
        }
        const origin = try snapshot(&f.tables, &f.handles);
        defer testing.allocator.free(origin);
        try f.journal.begin(f.scope, key_a, test_label);
        const gesture = f.journal.active.?;
        // Thirteen keys replace the eight- and sixteen-slot indexes.
        for (rows, 0..) |row, i| {
            try f.journal.touch(&f.tables, handle, row.row);
            try table.writeFieldSingle(i32, row, "value", @intCast(100 + i));
        }
        try f.journal.recordFree(&f.tables, handle, rows[0]);
        const active_index = f.journal.entryCount() - 1;
        try testing.expect(events.counts[@intFromEnum(EventKind.evicted)] > 0);
        try testing.expect(f.journal.active.? == gesture);
        try testing.expectEqual(@as(usize, 3), countRecords(&f.journal, active_index, .index));
        try testing.expectEqual(rows.len, dirtyRowCount(&f.journal));
        // Repeated touches find their relocated records without new bytes.
        const used = f.journal.bytesUsed();
        for (rows[1..]) |row| try f.journal.touch(&f.tables, handle, row.row);
        try testing.expectEqual(used, f.journal.bytesUsed());
        try testing.expectEqual(@as(u32, rows.len), f.journal.entry(active_index).?.rows);
        try f.journal.resetPreview(&f.tables);
        try expectSnapshot(origin, &f.tables, &f.handles);
        try f.journal.touch(&f.tables, handle, rows[5].row);
        try table.writeFieldSingle(i32, rows[5], "value", 55);
        const added = try f.journal.recordAlloc(&f.tables, handle);
        try table.writeFieldSingle(i32, added, "value", 77);
        if (commit_and_undo) {
            try f.journal.commit(&f.tables);
            _ = try f.journal.undo(&f.tables, key_a);
        } else try f.journal.cancel(&f.tables);
        try expectSnapshot(origin, &f.tables, &f.handles);
        try expectFreeListValid(table);
    }
}

test "table_journal index growth lifecycle snapshot and commit budget failures are mutation-free" {
    var f: Fixture = undefined;
    try f.init(8192, 8);
    defer f.deinit();
    const handle = f.handles[0];
    const table = f.tables.get(handle).?;
    var rows: [4]Table.RowHandle = undefined;
    for (&rows) |*row| row.* = try table.alloc();
    const origin = try snapshot(&f.tables, &f.handles);
    defer testing.allocator.free(origin);
    try f.journal.begin(f.scope, key_a, test_label);
    // One table and three rows fill half of the initial index.
    for (rows[0..3]) |row| try f.journal.touch(&f.tables, handle, row.row);
    const row_size = padded(@sizeOf(RowRecord) + 2 * rowImageSize(table));
    const index_size = padded(@sizeOf(IndexRecord) + 2 * initial_index_capacity * @sizeOf(usize));
    f.journal.retention = .{ .bytes = f.journal.used + row_size + index_size - 1 };
    {
        const frozen = try Frozen.capture(&f);
        defer frozen.deinit();
        try testing.expectError(error.BudgetExceeded, f.journal.touch(&f.tables, handle, rows[3].row));
        try frozen.expectUnchanged(&f);
    }
    // Freeing a recorded row needs only the first reusable-ID snapshot.
    const snapshot_size = padded(@sizeOf(FreeRecord) + table.reusableRows().len * @sizeOf(u32));
    f.journal.retention = .{ .bytes = f.journal.used + snapshot_size - 1 };
    {
        const frozen = try Frozen.capture(&f);
        defer frozen.deinit();
        try testing.expectError(error.BudgetExceeded, f.journal.recordFree(&f.tables, handle, rows[0]));
        try testing.expect(table.valid(rows[0]));
        try frozen.expectUnchanged(&f);
    }
    f.journal.retention = .{ .bytes = f.journal.used + snapshot_size };
    try f.journal.recordFree(&f.tables, handle, rows[0]);
    // Commit needs the lifecycle table's committed reusable IDs.
    {
        const frozen = try Frozen.capture(&f);
        defer frozen.deinit();
        try testing.expectError(error.BudgetExceeded, f.journal.commit(&f.tables));
        try frozen.expectUnchanged(&f);
    }
    try f.journal.cancel(&f.tables);
    try expectSnapshot(origin, &f.tables, &f.handles);
}

test "table_journal preview reset returns rows grown after the lifecycle snapshot to the prefix" {
    var f: Fixture = undefined;
    try f.init(32 * 1024, 2);
    defer f.deinit();
    const handle = f.handles[0];
    const table = f.tables.get(handle).?;
    while (table.reusableRows().len > 1) _ = try table.alloc();
    try f.journal.begin(f.scope, key_a, test_label);
    // The first lifecycle change snapshots the reusable IDs before growth.
    _ = try f.journal.recordAlloc(&f.tables, handle);
    try f.journal.resetPreview(&f.tables);
    try f.tables.grow(handle, table.rowCapacity() + 1);
    const grown = try snapshot(&f.tables, &f.handles);
    defer testing.allocator.free(grown);
    for (0..2) |_| {
        for (0..3) |_| {
            const row = try f.journal.recordAllocAt(&f.tables, handle, 0);
            try table.writeFieldSingle(i32, row, "value", 9);
        }
        try f.journal.resetPreview(&f.tables);
        try expectSnapshot(grown, &f.tables, &f.handles);
    }
    _ = try f.journal.recordAllocAt(&f.tables, handle, 0);
    try f.journal.commit(&f.tables);
    const committed = try snapshot(&f.tables, &f.handles);
    defer testing.allocator.free(committed);
    _ = try f.journal.undo(&f.tables, key_a);
    try expectSnapshot(grown, &f.tables, &f.handles);
    _ = try f.journal.redo(&f.tables, key_a);
    try expectSnapshot(committed, &f.tables, &f.handles);
    try expectFreeListValid(table);
}

const Events = struct {
    counts: [std.meta.fields(EventKind).len]usize = @splat(0),
    last: ?Event = null,
    fn notify(context: ?*anyopaque, event: Event) void {
        const self: *Events = @ptrCast(@alignCast(context.?));
        self.counts[@intFromEnum(event.kind)] += 1;
        self.last = event;
    }
    fn observer(self: *Events) Observer {
        return .{ .context = self, .notify = notify };
    }
};

test "table_journal budget eviction keeps every retained randomized entry exact" {
    var f: Fixture = undefined;
    try f.init(12 * 1024, 12);
    defer f.deinit();
    var events: Events = .{};
    f.journal.rebind(events.observer());
    var prng = std.Random.DefaultPrng.init(1847);
    var states: [81][]u8 = undefined;
    var captured: usize = 0;
    defer for (states[0..captured]) |state| testing.allocator.free(state);
    states[0] = try snapshot(&f.tables, &f.handles);
    captured += 1;
    for (1..states.len) |i| {
        try f.journal.begin(f.scope, key_a, test_label);
        try randomEdits(&f, prng.random(), 6);
        try f.journal.commit(&f.tables);
        states[i] = try snapshot(&f.tables, &f.handles);
        captured += 1;
        try testing.expect(f.journal.bytesUsed() <= 12 * 1024);
    }
    try testing.expect(events.counts[@intFromEnum(EventKind.evicted)] > 0);
    const retained = f.journal.entryCount();
    try testing.expect(retained > 0 and retained < states.len - 1);
    var i: usize = states.len - 1;
    for (0..retained) |_| {
        i -= 1;
        _ = try f.journal.undo(&f.tables, key_a);
        try expectSnapshot(states[i], &f.tables, &f.handles);
    }
    try testing.expectError(error.NoHistory, f.journal.undo(&f.tables, key_a));
    for (states[i + 1 ..]) |state| {
        _ = try f.journal.redo(&f.tables, key_a);
        try expectSnapshot(state, &f.tables, &f.handles);
    }
    try testing.expectEqual(@as(usize, 80), events.counts[@intFromEnum(EventKind.committed)]);
}

test "table_journal independent document lifecycle merges and physical reuse conflicts atomically" {
    var f: Fixture = undefined;
    try f.init(16 * 1024, 8);
    defer f.deinit();
    const handle = f.handles[0];
    const table = f.tables.get(handle).?;
    try f.journal.begin(f.scope, key_a, test_label);
    const a = try f.journal.recordAlloc(&f.tables, handle);
    try table.writeFieldSingle(i32, a, "value", 101);
    // Include a second table to prove preflight failure is all-or-nothing.
    const a2 = try f.journal.recordAlloc(&f.tables, f.handles[1]);
    try f.journal.commit(&f.tables);
    try f.journal.begin(f.scope, key_b, test_label);
    const b = try f.journal.recordAlloc(&f.tables, handle);
    try table.writeFieldSingle(i32, b, "value", 202);
    try f.journal.commit(&f.tables);
    _ = try f.journal.undo(&f.tables, key_a);
    try testing.expect(!table.isAllocated(a.row));
    try testing.expect(table.valid(b));
    try testing.expectEqual(@as(i32, 202), table.getField(i32, b, "value").?.*);
    try expectFreeListValid(table);
    _ = try f.journal.redo(&f.tables, key_a);
    try testing.expect(table.valid(a) and table.valid(b));
    // Free in A, then allocate the same slot in B. Undo A cannot revive A there.
    try f.journal.begin(f.scope, key_a, test_label);
    try f.journal.recordFree(&f.tables, f.handles[1], a2);
    try f.journal.recordFree(&f.tables, handle, a);
    try f.journal.commit(&f.tables);
    try f.journal.begin(f.scope, key_b, test_label);
    const reused = try f.journal.recordAlloc(&f.tables, handle);
    try testing.expect(a.row != reused.row);
    try f.journal.commit(&f.tables);
    _ = try f.journal.undo(&f.tables, key_a);
    try testing.expect(table.valid(a) and table.valid(b) and table.valid(reused));
    try testing.expect(f.tables.get(f.handles[1]).?.valid(a2));
    // Raw external allocation deliberately bypasses quarantine; conflict stays atomic.
    _ = try f.journal.redo(&f.tables, key_a);
    const raw = try table.alloc();
    try testing.expectEqual(a.row, raw.row);
    const before = try snapshot(&f.tables, &f.handles);
    defer testing.allocator.free(before);
    try testing.expectError(error.Conflict, f.journal.undo(&f.tables, key_a));
    try expectSnapshot(before, &f.tables, &f.handles);
    try expectFreeListValid(table);
}

test "table_journal new commit drops only its key redo while cancel preserves redo" {
    var f: Fixture = undefined;
    try f.init(8192, 8);
    defer f.deinit();
    for ([_]Atom{ key_a, key_b }, f.handles[0..2]) |key, handle| {
        try f.journal.begin(f.scope, key, test_label);
        _ = try f.journal.recordAlloc(&f.tables, handle);
        try f.journal.commit(&f.tables);
        _ = try f.journal.undo(&f.tables, key);
    }
    try f.journal.begin(f.scope, key_a, test_label);
    _ = try f.journal.recordAlloc(&f.tables, f.handles[0]);
    try f.journal.cancel(&f.tables);
    _ = try f.journal.redo(&f.tables, key_a);
    _ = try f.journal.undo(&f.tables, key_a);
    try f.journal.begin(f.scope, key_a, test_label);
    _ = try f.journal.recordAlloc(&f.tables, f.handles[0]);
    try f.journal.commit(&f.tables);
    try testing.expectError(error.NoHistory, f.journal.redo(&f.tables, key_a));
    _ = try f.journal.redo(&f.tables, key_b);
    try f.journal.clear(key_a);
    try testing.expectEqual(@as(usize, 1), f.journal.entryCount());
    try testing.expectEqual(key_b, f.journal.entry(0).?.key);
}

test "table_journal growth preserves history and active transaction cancellation" {
    var f: Fixture = undefined;
    try f.init(8192, 2);
    defer f.deinit();
    const handle = f.handles[0];
    const table = f.tables.get(handle).?;
    try f.journal.begin(f.scope, key_a, test_label);
    const row = try f.journal.recordAlloc(&f.tables, handle);
    try table.writeFieldSingle(i32, row, "value", 7);
    try f.journal.commit(&f.tables);
    try f.tables.grow(handle, 8);
    const grown = try snapshot(&f.tables, &f.handles);
    defer testing.allocator.free(grown);
    _ = try f.journal.undo(&f.tables, key_a);
    try testing.expect(table.rowCapacity() >= 8);
    try expectFreeListValid(table);
    _ = try f.journal.redo(&f.tables, key_a);
    try expectSnapshot(grown, &f.tables, &f.handles);
    try f.journal.begin(f.scope, key_a, test_label);
    try f.journal.touch(&f.tables, handle, row.row);
    try table.writeFieldSingle(i32, row, "value", 99);
    try f.tables.grow(handle, 16);
    for (0..9) |_| _ = try f.journal.recordAlloc(&f.tables, handle);
    try f.journal.cancel(&f.tables);
    try testing.expectEqual(@as(i32, 7), table.getField(i32, row, "value").?.*);
    try expectFreeListValid(table);
    try expectFreeListValid(table);
}

test "table_journal schema changes and destroyed tables fail without partial restore while smaller reservations retain history" {
    var f: Fixture = undefined;
    try f.init(8192, 8);
    defer f.deinit();
    try f.journal.begin(f.scope, key_a, test_label);
    for (f.handles) |handle| _ = try f.journal.recordAlloc(&f.tables, handle);
    try f.journal.commit(&f.tables);
    const table = f.tables.get(f.handles[1]).?;
    const schema = table.getSchema();
    schema.list.items[0].semantic_type = 123;
    const before = try snapshot(&f.tables, &f.handles);
    defer testing.allocator.free(before);
    try testing.expectError(error.SchemaChanged, f.journal.undo(&f.tables, key_a));
    try expectSnapshot(before, &f.tables, &f.handles);
    schema.list.items[0].semantic_type = 0;
    try f.tables.grow(f.handles[1], 4);
    // Smaller reservations retain all storage and history.
    try testing.expect(table.rowCapacity() >= 8);
    try f.tables.grow(f.handles[1], 8);
    f.tables.destroy(f.handles[2]);
    try testing.expectError(error.StaleTable, f.journal.undo(&f.tables, key_a));
    try testing.expect(f.tables.get(f.handles[0]).?.isAllocated(0));
    try f.journal.clear(key_a);
    try f.journal.begin(f.scope, key_a, test_label);
    try f.journal.touch(&f.tables, f.handles[0], 0);
    f.tables.get(f.handles[0]).?.getSchema().list.items[0].semantic_type = 456;
    try testing.expectError(error.SchemaChanged, f.journal.cancel(&f.tables));
    try f.journal.abandon();
    try testing.expect(!f.journal.inTransaction());
}

test "table_journal budget failure is mutation-free and cancel remains possible" {
    var f: Fixture = undefined;
    try f.init(1200, 16);
    defer f.deinit();
    const original = try snapshot(&f.tables, &f.handles);
    defer testing.allocator.free(original);
    try f.journal.begin(f.scope, key_a, test_label);
    const row = try f.journal.recordAlloc(&f.tables, f.handles[0]);
    f.journal.retention = .{ .bytes = f.journal.used };
    try testing.expectError(error.BudgetExceeded, f.journal.touch(&f.tables, f.handles[1], 0));
    try testing.expectError(error.BudgetExceeded, f.journal.commit(&f.tables));
    try testing.expect(f.tables.get(f.handles[0]).?.valid(row));
    try f.journal.cancel(&f.tables);
    try expectSnapshot(original, &f.tables, &f.handles);
}

test "table_journal reload rebind preserves control state without allocator callbacks" {
    var f: Fixture = undefined;
    try f.init(4096, 8);
    defer f.deinit();
    var old_events: Events = .{};
    var new_events: Events = .{};
    f.journal.rebind(old_events.observer());
    try f.journal.begin(f.scope, key_a, test_label);
    _ = try f.journal.recordAlloc(&f.tables, f.handles[0]);
    // Relocate the control struct and rebind while a gesture is still active.
    var reloaded = f.journal;
    reloaded.rebind(new_events.observer());
    try reloaded.commit(&f.tables);
    _ = try reloaded.undo(&f.tables, key_a);
    _ = try reloaded.redo(&f.tables, key_a);
    try testing.expectEqual(@as(usize, 1), old_events.counts[@intFromEnum(EventKind.began)]);
    try testing.expectEqual(@as(usize, 0), old_events.counts[@intFromEnum(EventKind.committed)]);
    try testing.expectEqual(@as(usize, 1), new_events.counts[@intFromEnum(EventKind.committed)]);
    try testing.expectEqual(key_a, new_events.last.?.entry.key);
    try testing.expectEqual(test_label, new_events.last.?.entry.label);
    reloaded.rebind(null);
    try reloaded.clear(key_a);
    try testing.expectEqual(@as(usize, 0), reloaded.entryCount());
}

test "table_journal unrelated document frees retain free-list entries and row bytes" {
    var f: Fixture = undefined;
    try f.init(8192, 8);
    defer f.deinit();
    const handle = f.handles[0];
    const table = f.tables.get(handle).?;
    const a = try table.alloc();
    const b = try table.alloc();
    try table.writeFieldSingle(i32, a, "value", 11);
    try table.writeFieldSingle(i32, b, "value", 22);
    try f.journal.begin(f.scope, key_a, test_label);
    try f.journal.recordFree(&f.tables, handle, a);
    try f.journal.commit(&f.tables);
    try f.journal.begin(f.scope, key_b, test_label);
    try f.journal.recordFree(&f.tables, handle, b);
    try f.journal.commit(&f.tables);
    const b_generation = table.rowGeneration(b.row);
    _ = try f.journal.undo(&f.tables, key_a);
    try testing.expect(table.valid(a));
    try testing.expectEqual(b_generation, table.rowGeneration(b.row));
    try testing.expect(!table.isAllocated(b.row));
    try expectFreeListValid(table);
    _ = try f.journal.redo(&f.tables, key_a);
    try expectFreeListValid(table);
    _ = try f.journal.undo(&f.tables, key_b);
    try testing.expect(table.valid(b));
    try testing.expectEqual(@as(i32, 22), table.getField(i32, b, "value").?.*);
    try expectFreeListValid(table);
}

fn expectRestoreAfterExternalFree(comptime commit_and_undo: bool) !void {
    var f: Fixture = undefined;
    try f.init(8192, 8);
    defer f.deinit();
    var external = try Journal.init(&f.memory, try f.nodeArena(), .{ .bytes = 8192 });
    const handle = f.handles[0];
    const table = f.tables.get(handle).?;
    const a = try table.alloc();
    const b = try table.alloc();
    const c = try table.alloc();
    try table.writeFieldSingle(i32, a, "value", 11);
    try table.writeFieldSingle(i32, b, "value", 22);
    const original = try snapshot(&f.tables, &f.handles);
    defer testing.allocator.free(original);

    try f.journal.begin(f.scope, key_a, test_label);
    try f.journal.touch(&f.tables, handle, a.row);
    // Neither b nor c is in A's table-level before-free-list. Only b will
    // subsequently be touched by A; c's external free entry must be preserved.
    try external.begin(f.scope, key_b, test_label);
    try external.recordFree(&f.tables, handle, c);
    try external.recordFree(&f.tables, handle, b);
    try external.commit(&f.tables);
    const before_edits = try snapshot(&f.tables, &f.handles);
    defer testing.allocator.free(before_edits);
    try table.writeFieldSingle(i32, a, "value", 99);
    const reused = try f.journal.recordAlloc(&f.tables, handle);
    try testing.expectEqual(b.row, reused.row);
    try table.writeFieldSingle(i32, reused, "value", 77);
    try expectFreeListValid(table);

    if (commit_and_undo) {
        try f.journal.commit(&f.tables);
        const committed = try snapshot(&f.tables, &f.handles);
        defer testing.allocator.free(committed);
        _ = try f.journal.undo(&f.tables, key_a);
        try expectFreeListValid(table);
        try expectSnapshot(before_edits, &f.tables, &f.handles);
        _ = try f.journal.redo(&f.tables, key_a);
        try expectFreeListValid(table);
        try expectSnapshot(committed, &f.tables, &f.handles);
        _ = try f.journal.undo(&f.tables, key_a);
    } else try f.journal.cancel(&f.tables);
    try expectFreeListValid(table);
    try expectSnapshot(before_edits, &f.tables, &f.handles);
    try testing.expectEqual(@as(u32, 1), table.count());
    _ = try external.undo(&f.tables, key_b);
    try expectFreeListValid(table);
    try expectSnapshot(original, &f.tables, &f.handles);
}

test "table_journal cancel retains rows freed externally before their first touch" {
    try expectRestoreAfterExternalFree(false);
}

test "table_journal undo redo retains rows freed externally before their first touch" {
    try expectRestoreAfterExternalFree(true);
}

test "table_journal evicting an undone entry discards the whole dependent redo chain" {
    var f: Fixture = undefined;
    try f.init(3200, 8);
    defer f.deinit();
    var events: Events = .{};
    f.journal.rebind(events.observer());
    for (0..2) |_| {
        try f.journal.begin(f.scope, key_a, test_label);
        _ = try f.journal.recordAlloc(&f.tables, f.handles[0]);
        try f.journal.commit(&f.tables);
    }
    try testing.expectEqual(@as(usize, 2), f.journal.entryCount());
    f.journal.retention = .{ .bytes = f.journal.used };
    _ = try f.journal.undo(&f.tables, key_a);
    _ = try f.journal.undo(&f.tables, key_a);
    try f.journal.begin(f.scope, key_b, test_label);
    _ = try f.journal.recordAlloc(&f.tables, f.handles[1]);
    try f.journal.commit(&f.tables);
    try testing.expectEqual(@as(usize, 2), events.counts[@intFromEnum(EventKind.evicted)]);
    try testing.expectEqual(@as(usize, 1), f.journal.entryCount());
    try testing.expectError(error.NoHistory, f.journal.redo(&f.tables, key_a));
    _ = try f.journal.undo(&f.tables, key_b);
    _ = try f.journal.redo(&f.tables, key_b);
}

test "table_journal commit across active growth has exact retained-capacity undo and redo" {
    var f: Fixture = undefined;
    try f.init(8192, 2);
    defer f.deinit();
    const handle = f.handles[0];
    const table = f.tables.get(handle).?;
    const baseline_row = try table.alloc();
    try f.tables.grow(handle, 8);
    const baseline = try snapshot(&f.tables, &f.handles);
    defer testing.allocator.free(baseline);
    try f.tables.grow(handle, 2);
    try f.journal.begin(f.scope, key_a, test_label);
    try f.journal.touch(&f.tables, handle, baseline_row.row);
    try table.writeFieldSingle(i32, baseline_row, "value", 1234);
    try f.tables.grow(handle, 8);
    for (0..4) |_| {
        const row = try f.journal.recordAlloc(&f.tables, handle);
        try table.writeFieldSingle(i32, row, "value", 876);
    }
    try f.journal.commit(&f.tables);
    const committed = try snapshot(&f.tables, &f.handles);
    defer testing.allocator.free(committed);
    _ = try f.journal.undo(&f.tables, key_a);
    try expectSnapshot(baseline, &f.tables, &f.handles);
    _ = try f.journal.redo(&f.tables, key_a);
    try expectSnapshot(committed, &f.tables, &f.handles);
}

test "table_journal invalid lifecycle and pointer fields fail before mutation" {
    var f: Fixture = undefined;
    try f.init(4096, 1);
    defer f.deinit();
    const handle = f.handles[0];
    const table = f.tables.get(handle).?;
    while (table.reusableRows().len > 1) _ = try table.alloc();
    try f.journal.begin(f.scope, key_a, test_label);
    const row = try f.journal.recordAlloc(&f.tables, handle);
    try testing.expectError(error.TableFull, f.journal.recordAlloc(&f.tables, handle));
    try testing.expectError(error.StaleRow, f.journal.touch(&f.tables, handle, table.rowCapacity()));
    try testing.expectError(error.StaleRow, f.journal.recordFree(&f.tables, handle, .{ .row = 0, .generation = row.generation + 1 }));
    table.required_singleton = true;
    try testing.expectError(error.RequiredSingleton, f.journal.recordFree(&f.tables, handle, row));
    table.required_singleton = false;
    try f.journal.cancel(&f.tables);
    var pointer_schema = test_schema;
    var fields = test_schema.fields[0..3].*;
    fields[0].contains_pointer = true;
    pointer_schema.fields = &fields;
    const pointer_handle = try f.tables.create(&pointer_schema, 1, Atom.from("pointer_table"), .durable);
    try f.journal.begin(f.scope, key_a, test_label);
    try testing.expectError(error.PointerField, f.journal.recordAlloc(&f.tables, pointer_handle));
    try testing.expectEqual(@as(u32, 0), f.tables.get(pointer_handle).?.count());
    try f.journal.cancel(&f.tables);
    f.tables.destroy(handle);
    const replacement = try f.tables.create(&test_schema, 1, Atom.from("replacement"), .durable);
    try testing.expectEqual(handle.index, replacement.index);
    try f.journal.begin(f.scope, key_a, test_label);
    try testing.expectError(error.StaleTable, f.journal.touch(&f.tables, handle, 0));
    try f.journal.cancel(&f.tables);
}

test "table_journal reservations active reuse final reference masks and rejection" {
    var f: Fixture = undefined;
    try f.init(32768, 8);
    defer f.deinit();
    const h = f.handles[0];
    const t = f.tables.get(h).?;
    try testing.expectError(error.NoTransaction, f.journal.recordAllocAt(&f.tables, h, 0));
    try f.journal.begin(f.scope, key_a, test_label);
    const original = try snapshot(&f.tables, &f.handles);
    defer testing.allocator.free(original);
    try expectAllocAtRejected(&f, h, t.reusableRows().len, error.InvalidFreeIndex);
    try expectSnapshot(original, &f.tables, &f.handles);
    const row = try f.journal.recordAlloc(&f.tables, h);
    try f.journal.recordFree(&f.tables, h, row);
    try testing.expect(f.journal.referencesRow(h, row.row, false));
    try testing.expect(!f.journal.referencesRow(h, row.row, true));
    const again = try f.journal.recordAlloc(&f.tables, h);
    try testing.expectEqual(row.row, again.row);
    try f.journal.cancel(&f.tables);
    try expectSnapshot(original, &f.tables, &f.handles);
    try testing.expect(!f.journal.referencesRow(h, row.row, false));
    try f.journal.begin(f.scope, key_a, test_label);
    try f.journal.touch(&f.tables, h, row.row);
    try f.journal.commit(&f.tables);
    try f.journal.begin(f.scope, key_b, test_label);
    try f.journal.touch(&f.tables, h, row.row);
    try f.journal.commit(&f.tables);
    var short: [0]bool = .{};
    try testing.expectError(error.InsufficientMask, f.journal.markReferencedRows(h, &short, false));
    const mask = try testing.allocator.alloc(bool, t.rowCapacity());
    defer testing.allocator.free(mask);
    @memset(mask, true);
    try f.journal.markReferencedRows(h, mask, false);
    try testing.expect(mask[row.row]);
    var stale = h;
    stale.generation +%= 1;
    try testing.expect(!f.journal.referencesRow(stale, row.row, false));
    try f.journal.begin(f.scope, key_a, test_label);
    try expectAllocAtRejected(&f, stale, 0, error.StaleTable);
    // Active exclusion must not hide the older same-key reference.
    try f.journal.touch(&f.tables, h, row.row);
    try testing.expect(f.journal.referencesRow(h, row.row, true));
    try expectAllocAtRejected(&f, h, t.reusableRows().len - 1, error.RowReserved);
    try f.journal.abandon();
    _ = try f.journal.undo(&f.tables, key_b);
    try testing.expect(f.journal.referencesRow(h, row.row, false));
    _ = try f.journal.redo(&f.tables, key_b);
    try f.journal.clear(key_a);
    try testing.expect(f.journal.referencesRow(h, row.row, false));
    try f.journal.clear(key_b);
    try testing.expect(!f.journal.referencesRow(h, row.row, false));
}

test "table_journal bounded window selection preserves last eligible ordering across sparse windows" {
    var f: Fixture = undefined;
    try f.init(65536, 601);
    defer f.deinit();
    const h = f.handles[0];
    const t = f.tables.get(h).?;
    // Keep three sparse free rows, including a final partial window.
    while (t.reusableRows().len > 0) _ = try t.alloc();
    for ([_]u32{ 257, 600, 1 }) |row| t.free(.{ .row = row, .generation = t.rowGeneration(row) });
    try f.journal.begin(f.scope, key_a, test_label);
    try f.journal.touch(&f.tables, h, 1);
    try f.journal.touch(&f.tables, h, 600);
    try f.journal.commit(&f.tables);
    try f.journal.begin(f.scope, key_a, test_label);
    const allocated = try f.journal.recordAlloc(&f.tables, h);
    try testing.expectEqual(@as(u32, 257), allocated.row);
    try t.reusableRows().expectEqual(&.{ 600, 1 });
    const before = try snapshot(&f.tables, &f.handles);
    defer testing.allocator.free(before);
    try testing.expectError(error.TableFull, f.journal.recordAlloc(&f.tables, h));
    try expectSnapshot(before, &f.tables, &f.handles);
    try f.journal.cancel(&f.tables);
}

test "table_journal allocation touch rejection preserves selected free order and bytes" {
    var f: Fixture = undefined;
    try f.init(@sizeOf(Entry), 8);
    defer f.deinit();
    try f.journal.begin(f.scope, key_a, test_label);
    const before = try snapshot(&f.tables, &f.handles);
    defer testing.allocator.free(before);
    try expectAllocAtRejected(&f, f.handles[0], 2, error.BudgetExceeded);
    try expectSnapshot(before, &f.tables, &f.handles);
    try f.journal.cancel(&f.tables);
}

test "table_journal redo branch discard and abandon release final references" {
    var f: Fixture = undefined;
    try f.init(8192, 8);
    defer f.deinit();
    const h = f.handles[0];
    try f.journal.begin(f.scope, key_a, test_label);
    try f.journal.touch(&f.tables, h, 0);
    try f.journal.commit(&f.tables);
    _ = try f.journal.undo(&f.tables, key_a);
    try testing.expect(f.journal.referencesRow(h, 0, false));
    try f.journal.begin(f.scope, key_a, test_label);
    try f.journal.touch(&f.tables, h, 1);
    try f.journal.commit(&f.tables);
    try testing.expect(!f.journal.referencesRow(h, 0, false));
    try f.journal.begin(f.scope, key_b, test_label);
    try f.journal.touch(&f.tables, h, 2);
    try f.journal.abandon();
    try testing.expect(!f.journal.referencesRow(h, 2, false));
    try testing.expect(f.journal.referencesRow(h, 1, false));
}

// Rejections include revision and the complete retained log, unlike restore
// snapshots whose revisions intentionally advance on undo/cancel.
const Frozen = struct {
    tables: []u8,
    revisions: [3]u64,
    used: usize,
    active: ?*Entry,
    sequence: u64,
    retention: Retention,
    journal_revision: u64,
    log_hash: u64,
    backing_bytes: u64,

    fn capture(f: *Fixture) !Frozen {
        const tables = try snapshot(&f.tables, &f.handles);
        var revisions: [3]u64 = undefined;
        for (f.handles, 0..) |h, i| revisions[i] = f.tables.get(h).?.revision;
        return .{
            .tables = tables,
            .revisions = revisions,
            .used = f.journal.used,
            .active = f.journal.active,
            .sequence = f.journal.next_sequence,
            .retention = f.journal.retention,
            .journal_revision = f.journal.revision,
            .log_hash = f.journal.contentHash(),
            .backing_bytes = f.memory.scopeFor(f.scope).?.stats().backing.current_bytes,
        };
    }
    fn deinit(self: Frozen) void {
        testing.allocator.free(self.tables);
    }
    fn expectUnchanged(self: Frozen, f: *Fixture) !void {
        try expectSnapshot(self.tables, &f.tables, &f.handles);
        for (f.handles, 0..) |h, i| try testing.expectEqual(self.revisions[i], f.tables.get(h).?.revision);
        try testing.expectEqual(self.used, f.journal.used);
        try testing.expectEqual(self.active, f.journal.active);
        try testing.expectEqual(self.sequence, f.journal.next_sequence);
        try testing.expectEqual(self.retention, f.journal.retention);
        try testing.expectEqual(self.journal_revision, f.journal.revision);
        try testing.expectEqual(self.log_hash, f.journal.contentHash());
        try testing.expectEqual(self.backing_bytes, f.memory.scopeFor(f.scope).?.stats().backing.current_bytes);
    }
};
fn expectAllocAtRejected(f: *Fixture, handle: Table.Handle, index: usize, expected: anyerror) !void {
    const frozen = try Frozen.capture(f);
    defer frozen.deinit();
    try testing.expectError(expected, f.journal.recordAllocAt(&f.tables, handle, index));
    try frozen.expectUnchanged(f);
}

test "table_journal selected allocation compacts and only final eviction releases reservation" {
    inline for (.{ false, true }) |commit_and_undo| {
        var f: Fixture = undefined;
        try f.init(8192, 8);
        defer f.deinit();
        const h = f.handles[0];
        const t = f.tables.get(h).?;
        // Two independent retained references to the same still-free row.
        for (0..2) |_| {
            try f.journal.begin(f.scope, key_a, test_label);
            try f.journal.touch(&f.tables, h, 0);
            try f.journal.commit(&f.tables);
        }
        const entry_size = f.journal.used / 2;
        const budget = f.journal.retention;
        // A first lifecycle touch records its table, row images, initial index
        // and the reusable IDs.
        const touch_size = padded(@sizeOf(TableRecord)) +
            padded(@sizeOf(RowRecord) + 2 * rowImageSize(t)) +
            padded(@sizeOf(IndexRecord) + initial_index_capacity * @sizeOf(usize)) +
            padded(@sizeOf(FreeRecord) + t.reusableRows().len * @sizeOf(u32));
        // Begin fits; the selected allocation's touch must evict exactly one.
        f.journal.retention = .{ .bytes = f.journal.used + @sizeOf(Entry) + touch_size - 1 };
        const baseline = try snapshot(&f.tables, &f.handles);
        defer testing.allocator.free(baseline);
        try f.journal.begin(f.scope, key_b, test_label);
        const selected_index = t.reusableRows().len - 6;
        const selected = try f.journal.recordAllocAt(&f.tables, h, selected_index);
        try testing.expectEqual(@as(u32, 5), selected.row);
        try testing.expectEqual(@as(usize, 2), f.journal.entryCount());
        try testing.expectEqual(@as(u64, 2), f.journal.entry(0).?.sequence);
        try expectFreeListValid(t);
        try testing.expect(f.journal.referencesRow(h, 0, false));
        const mask = try testing.allocator.alloc(bool, t.rowCapacity());
        defer testing.allocator.free(mask);
        try f.journal.markReferencedRows(h, mask, false);
        try testing.expect(mask[0]);
        if (commit_and_undo) {
            // Room for the commit's reusable-ID snapshot keeps the second reference.
            f.journal.retention = budget;
            try f.journal.commit(&f.tables);
            _ = try f.journal.undo(&f.tables, key_b);
        } else try f.journal.cancel(&f.tables);
        try expectSnapshot(baseline, &f.tables, &f.handles);
        // Only the second reference remains, until a later successful touch
        // needs its space. Ordinary allocation then chooses the released tail.
        try f.journal.clear(key_b);
        try testing.expect(f.journal.referencesRow(h, 0, false));
        f.journal.retention = .{ .bytes = entry_size + @sizeOf(Entry) + touch_size - 1 };
        try f.journal.begin(f.scope, key_b, test_label);
        _ = try f.journal.recordAllocAt(&f.tables, h, selected_index);
        try testing.expect(!f.journal.referencesRow(h, 0, false));
        try f.journal.markReferencedRows(h, mask, false);
        try testing.expect(!mask[0]);
        try f.journal.cancel(&f.tables);
        try expectSnapshot(baseline, &f.tables, &f.handles);
        try f.journal.begin(f.scope, key_b, test_label);
        const released = try f.journal.recordAlloc(&f.tables, h);
        try testing.expectEqual(@as(u32, 0), released.row);
        try f.journal.cancel(&f.tables);
    }
}

fn scopeBacking(f: *Fixture) u64 {
    return f.memory.scopeFor(f.scope).?.stats().backing.current_bytes;
}
fn scopeArenas(f: *Fixture) usize {
    return f.memory.scopeFor(f.scope).?.stats().dynamic_arena_count;
}

test "table_journal cancel undo prune and clear release obsolete generations" {
    var f: Fixture = undefined;
    try f.init(1024 * 1024, 1024);
    defer f.deinit();
    f.journal.retention = .unbounded;
    const h = f.handles[0];
    const table = f.tables.get(h).?;
    const row = try table.alloc();
    const baseline = scopeBacking(&f);

    // An empty transaction never allocates a generation.
    try f.journal.begin(f.scope, key_a, test_label);
    try testing.expectEqual(@as(usize, 0), scopeArenas(&f));
    try f.journal.commit(&f.tables);
    try testing.expectEqual(@as(usize, 0), f.journal.entryCount());

    for (0..16) |_| {
        try f.journal.begin(f.scope, key_a, test_label);
        try f.journal.touch(&f.tables, h, row.row);
        try testing.expectEqual(@as(usize, 1), scopeArenas(&f));
        try f.journal.cancel(&f.tables);
        try testing.expectEqual(baseline, scopeBacking(&f));
        try testing.expectEqual(@as(usize, 0), scopeArenas(&f));
    }

    // Growth past several generations keeps one arena and every image.
    const origin = try snapshot(&f.tables, &f.handles);
    defer testing.allocator.free(origin);
    try f.journal.begin(f.scope, key_a, test_label);
    var touched: u32 = 0;
    while (touched < table.rowCapacity()) : (touched += 1) try f.journal.touch(&f.tables, h, touched);
    try testing.expect(f.journal.bytesUsed() > 16 * initial_log_bytes);
    try testing.expectEqual(@as(usize, 1), scopeArenas(&f));
    try table.writeFieldSingle(i32, row, "value", 5);
    try f.journal.cancel(&f.tables);
    try expectSnapshot(origin, &f.tables, &f.handles);
    try testing.expectEqual(baseline, scopeBacking(&f));

    // Each new commit after an undo prunes the undone generation, so these do not accumulate.
    try f.journal.begin(f.scope, key_a, test_label);
    try f.journal.touch(&f.tables, h, row.row);
    try f.journal.commit(&f.tables);
    const one_entry = scopeBacking(&f);
    for (0..16) |_| {
        _ = try f.journal.undo(&f.tables, key_a);
        try f.journal.begin(f.scope, key_a, test_label);
        try f.journal.touch(&f.tables, h, row.row);
        try f.journal.commit(&f.tables);
        try testing.expectEqual(one_entry, scopeBacking(&f));
        try testing.expectEqual(@as(usize, 1), f.journal.entryCount());
    }
    try f.journal.clear(key_a);
    try testing.expectEqual(baseline, scopeBacking(&f));
    try testing.expectEqual(@as(usize, 0), f.journal.bytesUsed());
}

fn commitTouch(f: *Fixture, key: Atom, row: u32) !void {
    try f.journal.begin(f.scope, key, test_label);
    try f.journal.touch(&f.tables, f.handles[0], row);
    try f.journal.commit(&f.tables);
}

test "table_journal small entries share blocks that return only with their last entry" {
    var f: Fixture = undefined;
    try f.init(1024 * 1024, 16);
    defer f.deinit();
    f.journal.retention = .unbounded;
    const baseline = scopeBacking(&f);
    const table = f.tables.get(f.handles[0]).?;
    const row = try table.alloc();

    // The retained entries take far fewer arenas and pages than one each.
    const entry_count = 2000;
    try table.writeFieldSingle(i32, row, "value", 0);
    for (0..entry_count) |index| {
        try f.journal.begin(f.scope, key_a, test_label);
        try f.journal.touch(&f.tables, f.handles[0], row.row);
        try table.writeFieldSingle(i32, row, "value", @intCast(index + 1));
        try f.journal.commit(&f.tables);
    }
    const arenas = scopeArenas(&f);
    try testing.expect(arenas >= 2);
    try testing.expect(arenas * 10 < entry_count);
    const page_size = std.heap.pageSize();
    try testing.expect(scopeBacking(&f) - baseline < entry_count * page_size / 4);

    // Every image survives sharing, down to the oldest: each entry holds its own value.
    for (0..entry_count) |index| {
        _ = try f.journal.undo(&f.tables, key_a);
        const expected: i32 = @intCast(entry_count - 1 - index);
        try testing.expectEqual(expected, table.getField(i32, row, "value").?.*);
    }
    for (0..entry_count) |index| {
        _ = try f.journal.redo(&f.tables, key_a);
        const expected: i32 = @intCast(index + 1);
        try testing.expectEqual(expected, table.getField(i32, row, "value").?.*);
    }

    // Another key does not hold this key's block, so closing it returns everything of its own.
    const with_a = scopeBacking(&f);
    for (0..8) |_| try commitTouch(&f, key_b, row.row);
    try testing.expect(scopeBacking(&f) > with_a);
    try f.journal.clear(key_b);
    try testing.expectEqual(with_a, scopeBacking(&f));

    // A shared block outlives all but its last entry. Oldest-first release shows it.
    f.journal.retention = .{ .bytes = f.journal.bytesUsed() };
    const full = scopeArenas(&f);
    var evicted_entries: usize = 0;
    while (scopeArenas(&f) == full) : (evicted_entries += 1) {
        try f.journal.setRetention(.{ .bytes = f.journal.bytesUsed() - 1 });
    }
    try testing.expect(evicted_entries > 1);

    f.journal.retention = .unbounded;
    try f.journal.clear(key_a);
    try testing.expectEqual(baseline, scopeBacking(&f));
    try testing.expectEqual(@as(usize, 0), scopeArenas(&f));
}

test "table_journal the newest entry returns its bytes to a block other entries hold" {
    var f: Fixture = undefined;
    try f.init(1024 * 1024, 16);
    defer f.deinit();
    f.journal.retention = .unbounded;
    const table = f.tables.get(f.handles[0]).?;
    const row = try table.alloc();
    try commitTouch(&f, key_a, row.row);
    const block = f.journal.first.?.block.?;
    const used = block.used;
    try testing.expectEqual(f.journal.first.?.used, used);
    for (0..64) |_| {
        try f.journal.begin(f.scope, key_a, test_label);
        try f.journal.touch(&f.tables, f.handles[0], row.row);
        try testing.expect(f.journal.active.?.block.? == block);
        try f.journal.cancel(&f.tables);
        try testing.expectEqual(used, block.used);
    }
    try testing.expectEqual(@as(u32, 1), block.live);
}

test "table_journal a reopened Atom never joins a released incarnation's block" {
    var f: Fixture = undefined;
    try f.init(1024 * 1024, 16);
    defer f.deinit();
    f.journal.retention = .unbounded;
    const level = Atom.from("journal_level");
    const first = try f.memory.openScope(level);
    const row = try f.tables.get(f.handles[0]).?.alloc();
    try f.journal.begin(first, key_a, test_label);
    try f.journal.touch(&f.tables, f.handles[0], row.row);
    try f.journal.commit(&f.tables);
    const stale_block = f.journal.first.?.block.?;
    try f.memory.beginCloseScope(first);
    try f.memory.releaseScope(first);

    const second = try f.memory.openScope(level);
    try f.journal.begin(second, key_a, test_label);
    try f.journal.touch(&f.tables, f.handles[0], row.row);
    try f.journal.commit(&f.tables);
    try testing.expect(f.journal.last.?.block.? != stale_block);
    // Forgetting the stale entry follows no pointer into the released arena.
    try f.journal.clear(key_a);
    try testing.expectEqual(@as(usize, 0), f.memory.scopeFor(second).?.stats().dynamic_arena_count);
}

test "table_journal a refused block leaves the full one open" {
    var f: Fixture = undefined;
    try f.init(1024 * 1024, 4096);
    defer f.deinit();
    f.journal.retention = .unbounded;
    const pages = &f.memory.page_source;
    f.scope = try f.memory.openScope(Atom.from("journal_refusing"));
    const table = f.tables.get(f.handles[0]).?;
    const row = try table.alloc();
    try commitTouch(&f, key_a, row.row);
    const shared = f.journal.first.?.block.?;
    pages.refuseAfter(0);
    try f.journal.begin(f.scope, key_a, test_label);
    var touched: u32 = 0;
    const refused: anyerror = while (touched < table.rowCapacity()) : (touched += 1) {
        f.journal.touch(&f.tables, f.handles[0], touched) catch |err| break err;
    } else return error.TestExpectedRefusal;
    try testing.expectEqual(@as(anyerror, error.OutOfMemory), refused);
    try f.journal.cancel(&f.tables);
    pages.refuseNone();
    try testing.expect(shared.open);
    // The space is usable again without any page.
    const allocations = pages.allocations.load(.monotonic);
    try commitTouch(&f, key_a, row.row);
    try testing.expectEqual(allocations, pages.allocations.load(.monotonic));
}

test "table_journal a log past half a block takes its own and leaves the shared block open" {
    var f: Fixture = undefined;
    try f.init(1024 * 1024, 4096);
    defer f.deinit();
    f.journal.retention = .unbounded;
    const table = f.tables.get(f.handles[0]).?;
    const row = try table.alloc();
    try commitTouch(&f, key_a, row.row);
    const shared = f.journal.first.?.block.?;
    try f.journal.begin(f.scope, key_a, test_label);
    var touched: u32 = 0;
    while (touched < table.rowCapacity()) : (touched += 1) try f.journal.touch(&f.tables, f.handles[0], touched);
    const active = f.journal.active.?;
    try testing.expect(active.used > shared_log_limit);
    try testing.expect(active.block.? != shared);
    try f.journal.commit(&f.tables);
    try commitTouch(&f, key_a, row.row);
    try testing.expect(f.journal.last.?.block.? == shared);
    try testing.expectEqual(@as(u32, 2), shared.live);
}

test "table_journal refused pages leave history tables and the open transaction unchanged" {
    var f: Fixture = undefined;
    try f.init(1024 * 1024, 4096);
    defer f.deinit();
    f.journal.retention = .unbounded;
    const pages = &f.memory.page_source;
    f.scope = try f.memory.openScope(Atom.from("journal_refusing"));
    const h = f.handles[0];
    const table = f.tables.get(h).?;
    try f.journal.begin(f.scope, key_b, test_label);
    try f.journal.touch(&f.tables, h, 0);
    try f.journal.commit(&f.tables);
    const origin = try snapshot(&f.tables, &f.handles);
    defer testing.allocator.free(origin);

    // Refused first generation: the transaction stays open with nothing recorded.
    pages.refuseAfter(0);
    try f.journal.begin(f.scope, key_a, test_label);
    {
        const frozen = try Frozen.capture(&f);
        defer frozen.deinit();
        try testing.expectError(error.OutOfMemory, f.journal.touch(&f.tables, h, 1));
        try testing.expectError(error.OutOfMemory, f.journal.recordAlloc(&f.tables, h));
        try frozen.expectUnchanged(&f);
    }

    // A limit that needs the older entry evicted: the refusal comes first, so it survives.
    f.journal.retention = .{ .bytes = f.journal.used };
    {
        const frozen = try Frozen.capture(&f);
        defer frozen.deinit();
        try testing.expectError(error.OutOfMemory, f.journal.touch(&f.tables, h, 1));
        try frozen.expectUnchanged(&f);
    }
    f.journal.retention = .unbounded;

    // Refused later generation: the old one still holds every image.
    pages.refuseNone();
    var row: u32 = 1;
    try f.journal.touch(&f.tables, h, row);
    pages.refuseAfter(0);
    const refused: anyerror = while (row + 1 < table.rowCapacity()) {
        row += 1;
        const frozen = try Frozen.capture(&f);
        defer frozen.deinit();
        f.journal.touch(&f.tables, h, row) catch |err| {
            try frozen.expectUnchanged(&f);
            break err;
        };
    } else return error.TestExpectedRefusal;
    try testing.expectEqual(@as(anyerror, error.OutOfMemory), refused);
    try f.journal.cancel(&f.tables);
    try expectSnapshot(origin, &f.tables, &f.handles);

    pages.refuseNone();
    _ = try f.journal.undo(&f.tables, key_b);
    _ = try f.journal.redo(&f.tables, key_b);
}

const blob_bytes = 1024 * 1024;
const blob_schema: Table.Schema = .{ .fields = &.{
    .{ .name = "blob", .size = blob_bytes, .stride = blob_bytes, .column_index = 0, .bit = 0 },
} };

test "table_journal unbounded retention crosses 64 MiB until a policy limit evicts oldest across keys" {
    const former_budget = 64 * 1024 * 1024;
    var f: Fixture = undefined;
    try f.init(1024 * 1024, 1);
    defer f.deinit();
    f.journal.retention = .unbounded;
    var events: Events = .{};
    f.journal.rebind(events.observer());
    const other = try f.memory.openScope(Atom.from("journal_other"));
    // One entry alone passes the former limit, as does the aggregate of a second key.
    const big = try f.tables.create(&blob_schema, 40, Atom.from("blob_big"), .durable);
    const peer = try f.tables.create(&blob_schema, 20, Atom.from("blob_peer"), .durable);
    const tables = [_]Table.Handle{ big, peer };
    const scopes = [_]Scope.Id{ f.scope, other };
    const keys = [_]Atom{ key_a, key_b };
    for (tables, scopes, keys) |handle, scope, key| {
        const table = f.tables.get(handle).?;
        try f.journal.begin(scope, key, test_label);
        while (table.reusableRows().len != 0) {
            const row = try f.journal.recordAlloc(&f.tables, handle);
            @memset(table.rowFieldBytes(row.row, 0), @truncate(row.row + 1));
        }
        try f.journal.commit(&f.tables);
    }
    try testing.expect(f.journal.entry(0).?.bytes > former_budget);
    try testing.expect(f.journal.bytesUsed() > former_budget + 32 * 1024 * 1024);
    try testing.expectEqual(@as(usize, 0), events.counts[@intFromEnum(EventKind.evicted)]);
    // Each scope is charged its own entry, not the aggregate.
    try testing.expect(f.memory.scopeFor(f.scope).?.stats().backing.current_bytes > former_budget);
    const other_bytes = f.memory.scopeFor(other).?.stats().backing.current_bytes;
    try testing.expect(other_bytes > 32 * 1024 * 1024 and other_bytes < former_budget);

    const big_table = f.tables.get(big).?;
    _ = try f.journal.undo(&f.tables, key_a);
    try testing.expectEqual(@as(u32, 0), big_table.count());
    _ = try f.journal.redo(&f.tables, key_a);
    try testing.expectEqual(@as(u32, 40), big_table.count());
    try testing.expectEqual(@as(u8, 40), big_table.rowFieldBytes(39, 0)[blob_bytes - 1]);

    // A limit that holds only the newer entry evicts the older key's and returns its pages.
    try f.journal.setRetention(.{ .bytes = 48 * 1024 * 1024 });
    try testing.expectEqual(@as(usize, 1), events.counts[@intFromEnum(EventKind.evicted)]);
    try testing.expectEqual(key_b, f.journal.entry(0).?.key);
    try testing.expectEqual(@as(u64, 0), f.memory.scopeFor(f.scope).?.stats().backing.current_bytes);
    try testing.expectError(error.NoHistory, f.journal.undo(&f.tables, key_a));
    _ = try f.journal.undo(&f.tables, key_b);
    try testing.expectEqual(@as(u32, 0), f.tables.get(peer).?.count());
}

test "table_journal entries of a released scope are never read and can be forgotten" {
    var f: Fixture = undefined;
    try f.init(64 * 1024, 4096);
    defer f.deinit();
    f.journal.retention = .unbounded;
    const level = Atom.from("journal_level");
    const released = try f.memory.openScope(level);
    const h = f.handles[0];
    const table = f.tables.get(h).?;
    // The tables outlive the scope, so only the log check can stand between these and freed pages.
    try f.journal.begin(released, key_a, test_label);
    try f.journal.touch(&f.tables, h, 0);
    try f.journal.commit(&f.tables);
    try f.journal.begin(f.scope, key_b, test_label);
    try f.journal.touch(&f.tables, h, 1);
    try f.journal.commit(&f.tables);
    try f.journal.begin(released, key_a, test_label);
    try f.journal.touch(&f.tables, h, 2);
    try f.memory.beginCloseScope(released);

    // A closing scope grows no new generation, and cancel needs none.
    var row: u32 = 3;
    const refused: anyerror = while (row < table.rowCapacity()) : (row += 1) {
        f.journal.touch(&f.tables, h, row) catch |err| break err;
    } else return error.TestExpectedRefusal;
    try testing.expectEqual(@as(anyerror, error.ScopeClosing), refused);
    const parked_active = f.journal.active;
    f.journal.active = null;
    try testing.expectError(error.ScopeClosing, f.journal.begin(released, key_a, test_label));
    f.journal.active = parked_active;
    try f.memory.releaseScope(released);
    try testing.expectError(error.StaleTable, f.journal.touch(&f.tables, h, 3));
    try testing.expectError(error.StaleTable, f.journal.commit(&f.tables));
    try testing.expectError(error.StaleTable, f.journal.cancel(&f.tables));
    try f.journal.abandon();

    try testing.expectError(error.StaleScope, f.journal.begin(released, key_a, test_label));
    try testing.expectError(error.StaleTable, f.journal.undo(&f.tables, key_a));
    try testing.expect(!f.journal.referencesRow(h, 0, false));
    try testing.expect(f.journal.referencesRow(h, 1, false));
    try testing.expectEqual(@as(?Table.Handle, null), f.journal.entryTable(0, 0));
    _ = try f.journal.undo(&f.tables, key_b);
    _ = try f.journal.redo(&f.tables, key_b);
    const remaining = f.journal.entry(1).?.bytes;
    try f.journal.clear(key_a);
    try testing.expectEqual(@as(usize, 1), f.journal.entryCount());
    try testing.expectEqual(remaining, f.journal.bytesUsed());
    const reopened = try f.memory.openScope(level);
    try f.journal.begin(reopened, key_a, test_label);
    try f.journal.touch(&f.tables, h, 0);
    try f.journal.commit(&f.tables);
    _ = try f.journal.undo(&f.tables, key_a);
}

test "table_journal removal inside an admission is refused and keeps the entry's log" {
    var f: Fixture = undefined;
    try f.init(64 * 1024, 8);
    defer f.deinit();
    const h = f.handles[0];
    const table = f.tables.get(h).?;
    const row = try table.alloc();
    try f.journal.begin(f.scope, key_a, test_label);
    try f.journal.touch(&f.tables, h, row.row);
    try f.journal.commit(&f.tables);
    _ = try f.journal.undo(&f.tables, key_a);
    try f.journal.begin(f.scope, key_b, test_label);
    try f.journal.touch(&f.tables, h, row.row);
    try table.writeFieldSingle(i32, row, "value", 9);
    const log_hash = f.journal.contentHash();
    const admission = try f.memory.beginInitAdmission();
    try testing.expectError(error.AdmissionMutationRejected, f.journal.cancel(&f.tables));
    try testing.expectError(error.AdmissionMutationRejected, f.journal.abandon());
    try testing.expectError(error.AdmissionMutationRejected, f.journal.clear(key_a));
    try testing.expectError(error.AdmissionMutationRejected, f.journal.setRetention(.{ .bytes = @sizeOf(Entry) }));
    try testing.expectEqual(log_hash, f.journal.contentHash());
    try testing.expectEqual(@as(i32, 9), table.getField(i32, row, "value").?.*);
    try testing.expectError(error.AdmissionMutationRejected, f.journal.setRetention(.unbounded));
    try testing.expectEqual(@as(usize, 64 * 1024), f.journal.retention.bytes);
    try testing.expectError(error.AdmissionMutationRejected, f.memory.validateInitAdmission(admission));
    try testing.expect(f.memory.abortInitAdmission(admission));
    try f.journal.cancel(&f.tables);

    // A new commit would prune key_a's undone entry; an empty one would not.
    try f.journal.begin(f.scope, key_a, test_label);
    const empty_commit = try f.memory.beginInitAdmission();
    try f.journal.commit(&f.tables);
    try f.memory.validateInitAdmission(empty_commit);
    try testing.expect(f.memory.abortInitAdmission(empty_commit));
    try f.journal.begin(f.scope, key_a, test_label);
    try f.journal.touch(&f.tables, h, row.row);
    const pruning_commit = try f.memory.beginInitAdmission();
    try testing.expectError(error.AdmissionMutationRejected, f.journal.commit(&f.tables));
    try testing.expect(f.memory.abortInitAdmission(pruning_commit));
    try f.journal.cancel(&f.tables);

    // Making room would evict, though this row fits the entry's current mapping, so only
    // the retention check stands before the eviction.
    _ = try f.journal.redo(&f.tables, key_a);
    try f.journal.begin(f.scope, key_b, test_label);
    try f.journal.touch(&f.tables, h, 1);
    f.journal.retention = .{ .bytes = f.journal.used };
    const evicting = try f.memory.beginInitAdmission();
    try testing.expectError(error.AdmissionMutationRejected, f.journal.touch(&f.tables, h, 2));
    try testing.expectEqual(@as(usize, 2), f.journal.entryCount());
    try testing.expect(f.memory.abortInitAdmission(evicting));
    try f.journal.cancel(&f.tables);
    try testing.expectError(error.BudgetExceeded, f.journal.setRetention(.{ .bytes = 0 }));
}

test "table_journal undo and redo restore presence bits past the first mask word" {
    var f: Fixture = .{};
    try f.init(1 << 20, 4);
    defer f.deinit();
    var kw: Atom.Registry = undefined;
    try kw.init(&f.memory);
    defer kw.deinit();
    var schema: Table.Schema = undefined;
    try schema.init(testing.allocator, &kw, 100);
    defer schema.deinit();
    var name_buffer: [8]u8 = undefined;
    for (0..100) |i| schema.addFieldType(std.fmt.bufPrint(&name_buffer, "f{d}", .{i}) catch unreachable, .i32, 4, .int);
    const handle = try f.tables.create(&schema, 4, Atom.from("wide_journal"), .durable);
    const table = f.tables.get(handle).?;
    const row = try table.alloc();
    const value: i32 = 42;

    try f.journal.begin(f.scope, key_a, test_label);
    try f.journal.touch(&f.tables, handle, row.row);
    table.writeFieldRawByIndex(row, 99, std.mem.asBytes(&value));
    table.writeFieldRawByIndex(row, 70, std.mem.asBytes(&value));
    try f.journal.commit(&f.tables);
    const after = table.rowMask(row.row);
    try testing.expect(after.has(99) and after.has(70));

    _ = try f.journal.undo(&f.tables, key_a);
    try testing.expect(table.rowMask(row.row).isEmpty());
    _ = try f.journal.redo(&f.tables, key_a);
    try testing.expect(table.rowMask(row.row).eql(after));
    try testing.expectEqual(value, table.getField(i32, row, "f99").?.*);
}
