//! The log's moving parts behind `log.zig`: the registry of logging threads, each with a ring
//! of its own, and the background writer, the one thread that reads every ring and writes
//! the file, the console echo, the zone history and the notices.
//!
//! A thread that logs registers itself (`Registry.register`) and gets an `Entry`: its ring,
//! its lane in the profiler, and the zones it has open. It alone writes that ring. The
//! writer thread (`BackgroundWriter`) walks the registry's list, drains each ring in turn and
//! sleeps between passes that find nothing. Nothing here is called by a plugin or a kernel:
//! `log.zig` is the interface, and the host owns the lifetime.
const std = @import("std");
const Atom = @import("../atom.zig").Atom;
const fmt = @import("format.zig");
const decoder = @import("decoder.zig");
const SpscRingBuffer = @import("buffer.zig").SpscRingBuffer;
const zones = @import("zones.zig");
const Notices = @import("notices.zig").Notices;

/// The longest thread name an entry keeps, for messages about its ring.
pub const max_thread_name = 32;

/// A zone begun and not yet ended, in its producer's entry: the `scope` tag and `name` hash it
/// was begun with, and `begin_ns`, when (`log.now`).
pub const OpenZone = struct { scope: u32, name: u64, begin_ns: u64 };

/// Who an entry belongs to: `live`, a registered thread's; `retired`, no thread's, waiting to
/// be taken; `claiming`, being taken by a registering thread. Only its producer moves it from
/// `live` to `retired`, and only the registering thread whose compare-and-swap takes it from
/// `retired` moves it on, through `claiming`, back to `live`. Each move publishes the fields
/// written before it.
pub const EntryState = enum(u8) { live, retired, claiming };

/// One logging thread's place in the registry: its ring and what the log knows of the
/// thread. It never moves or leaves the list before `Registry.deinit`; a thread that stops
/// logging retires it for the next thread that registers.
pub const Entry = struct {
    /// The thread's ring: this entry's producer writes it, the writer thread reads it.
    buffer: *SpscRingBuffer,
    /// The entry's place in the registry, fixed when it is appended: its zones' lane.
    lane: u16,
    /// The producer's open zones, innermost last; touched only by this entry's producer.
    open_zones: [zones.max_depth]OpenZone = undefined,
    /// How many zones the producer has open: the next free index of `open_zones`.
    zone_depth: u16 = 0,
    /// The thread's name. Written with `thread_id`, and read only by this entry's producer.
    name: [max_thread_name]u8 = @splat(0),
    /// The bytes of `name` in use.
    name_len: u8 = 0,
    /// The producer's thread id. Written only while `claiming`, before the entry is `live`
    /// again.
    thread_id: std.atomic.Value(u64),
    /// The interner the producer's records read atoms' names from (`log.setThreadAtoms`).
    /// Accessed only by this entry's producer, never by the background writer. A claim
    /// writes it, ordered after the previous producer by `state`.
    atoms: ?*Atom.Registry = null,
    /// Whose the entry is; see `EntryState`.
    state: std.atomic.Value(EntryState) = .init(.live),
    /// The entry appended after this one; null at the list's end. Set once.
    next: std.atomic.Value(?*Entry) = std.atomic.Value(?*Entry).init(null),

    /// Keeps the first `max_thread_name` bytes.
    fn setName(entry: *Entry, name: []const u8) void {
        const kept = name[0..@min(name.len, max_thread_name)];
        @memcpy(entry.name[0..kept.len], kept);
        entry.name_len = @intCast(kept.len);
    }

    /// The thread's name, cut to `max_thread_name` bytes, for messages about its ring. For the
    /// entry's producer to read.
    pub fn threadName(entry: *const Entry) []const u8 {
        return entry.name[0..entry.name_len];
    }

    /// Its producer's alone, after its last record: the next thread to register may take it.
    pub fn retire(entry: *Entry) void {
        entry.atoms = null;
        entry.state.store(.retired, .release);
    }
};

/// Entries form a list that only appends, so the writer and producers walk it without a
/// lock and an entry never moves or leaves before `deinit`. A retired entry waits for the
/// next thread to register. A registering thread that finds none retired as it walks the list
/// appends one, so storage follows the peak number of live logging threads, plus any entry
/// retired just after a registering thread walked past it. Registering, retiring and looking
/// up never wait for another thread. `allocator` runs on the registering thread and must be
/// thread-safe.
pub const Registry = struct {
    /// Why a thread did not register: it is registered already, or no ring could be allocated.
    pub const RegisterError = error{DuplicateThread} || std.mem.Allocator.Error;

    /// The list's first entry; null until a thread registers.
    first: std.atomic.Value(?*Entry) = std.atomic.Value(?*Entry).init(null),
    /// Entries appended so far: the next entry's lane.
    lane_count: std.atomic.Value(u32) = .init(0),

    /// Registers the thread whose id is `thread_id`, called on that thread, as the sole
    /// producer of a ring: a retired entry's when there is one, else one of `ring_bytes`
    /// allocated with `allocator`. `name` is copied, cut to `max_thread_name` bytes. Fails
    /// with `error.DuplicateThread` when the thread has a live entry, and
    /// `error.OutOfMemory`.
    pub fn register(self: *Registry, allocator: std.mem.Allocator, thread_id: u64, name: []const u8, ring_bytes: u32) RegisterError!void {
        if (self.lookupThread(thread_id) != null) return error.DuplicateThread;
        if (self.claimRetired(thread_id, name)) return;
        const buffer = try SpscRingBuffer.init(allocator, ring_bytes);
        errdefer buffer.deinit(allocator);
        try self.append(allocator, buffer, thread_id, name);
    }

    /// True when `thread_id` now owns a retired entry and its ring. The ring keeps unread
    /// records; only its producer changes, and the old one stopped before retiring.
    fn claimRetired(self: *Registry, thread_id: u64, name: []const u8) bool {
        var it = self.first.load(.acquire);
        while (it) |entry| : (it = entry.next.load(.acquire)) {
            // Acquire on success: the retired producer's last writes come before the claim's.
            const taken = entry.state.cmpxchgStrong(.retired, .claiming, .acquire, .monotonic) == null;
            if (!taken) continue;
            entry.atoms = null;
            entry.zone_depth = 0;
            entry.setName(name);
            entry.thread_id.store(thread_id, .monotonic);
            entry.state.store(.live, .release);
            return true;
        }
        return false;
    }

    /// Links a new entry after the list's last, whichever thread appended that one.
    fn append(self: *Registry, allocator: std.mem.Allocator, buffer: *SpscRingBuffer, thread_id: u64, name: []const u8) std.mem.Allocator.Error!void {
        const entry = try allocator.create(Entry);
        const lane = self.lane_count.fetchAdd(1, .monotonic);
        if (lane > std.math.maxInt(u16)) std.debug.panic("log: more than {d} threads have logged at once", .{std.math.maxInt(u16)});
        entry.* = .{ .buffer = buffer, .lane = @intCast(lane), .thread_id = std.atomic.Value(u64).init(thread_id) };
        entry.setName(name);
        // Release on success publishes the entry's fields to every walker of the list.
        // A failed exchange returns the entry already there, which is never null.
        const first_found = self.first.cmpxchgStrong(null, entry, .release, .acquire) orelse return;
        var tail = first_found.?;
        while (true) {
            const next_found = tail.next.cmpxchgStrong(null, entry, .release, .acquire) orelse return;
            tail = next_found.?;
        }
    }

    /// Frees the entries; their rings belong to whoever releases them first. No producer
    /// or writer may still be running.
    pub fn deinit(self: *Registry, allocator: std.mem.Allocator) void {
        var it = self.first.load(.acquire);
        while (it) |entry| {
            it = entry.next.load(.acquire);
            allocator.destroy(entry);
        }
        self.first.store(null, .release);
    }

    /// The live entry of the thread whose id is `tid`, or null when it has none: it never
    /// registered, or it retired. Walks the list; takes no lock.
    pub fn lookupThread(self: *Registry, tid: u64) ?*Entry {
        var it = self.first.load(.acquire);
        while (it) |entry| : (it = entry.next.load(.acquire)) {
            if (entry.state.load(.acquire) != .live) continue;
            if (entry.thread_id.load(.monotonic) == tid) return entry;
        }
        return null;
    }

    test "thread registry rejects duplicates, passes the old fixed count and reuses retired rings" {
        const allocator = std.testing.allocator;
        var registry = Registry{};
        defer registry.deinit(allocator);
        const buffer = try SpscRingBuffer.init(allocator, test_ring_bytes);
        defer buffer.deinit(allocator);

        // A hundred threads, sharing one ring to stay cheap: the list has no fixed size.
        for (1..101) |id| try registry.append(allocator, buffer, id, "worker");
        try std.testing.expectError(error.DuplicateThread, registry.register(allocator, 1, "worker", test_ring_bytes));
        try std.testing.expectEqual(buffer, registry.lookupThread(100).?.buffer);

        const retired = registry.lookupThread(1).?;
        retired.retire();
        try std.testing.expect(registry.lookupThread(1) == null);
        try std.testing.expectEqual(buffer, registry.lookupThread(2).?.buffer);

        // No new ring is allocated: a leak here would fail the test allocator.
        try registry.register(allocator, 1000, "later", test_ring_bytes);
        try std.testing.expectEqual(retired, registry.lookupThread(1000).?);
        try std.testing.expectEqualStrings("later", retired.threadName());
        // A kernel can reuse a finished thread's ID, which then registers normally.
        retired.retire();
        try registry.register(allocator, 1000, "later", test_ring_bytes);
        try std.testing.expectEqual(retired, registry.lookupThread(1000).?);
    }

    test "threads registering and retiring at once each own one entry, and reuse retired ones" {
        const allocator = std.heap.page_allocator;
        var registry = Registry{};
        defer {
            var it = registry.first.load(.acquire);
            while (it) |entry| : (it = entry.next.load(.acquire)) entry.buffer.deinit(allocator);
            registry.deinit(allocator);
        }
        const thread_count = 8;
        const Worker = struct {
            fn run(shared: *Registry, worker_index: usize, failed: *std.atomic.Value(bool)) void {
                for (0..200) |round| {
                    // Unique across workers and rounds, as a kernel's thread IDs are at one time.
                    const thread_id: u64 = 1 + worker_index * 1000 + round;
                    shared.register(std.heap.page_allocator, thread_id, "worker", 4096) catch {
                        failed.store(true, .monotonic);
                        return;
                    };
                    const entry = shared.lookupThread(thread_id) orelse {
                        failed.store(true, .monotonic);
                        return;
                    };
                    const owned = entry.thread_id.load(.monotonic) == thread_id and entry.state.load(.acquire) == .live;
                    if (!owned) failed.store(true, .monotonic);
                    entry.retire();
                }
            }
        };
        var failed: std.atomic.Value(bool) = .init(false);
        var workers: [thread_count]std.Thread = undefined;
        for (&workers, 0..) |*worker, index| worker.* = try std.Thread.spawn(.{}, Worker.run, .{ &registry, index, &failed });
        for (workers) |worker| worker.join();
        try std.testing.expect(!failed.load(.monotonic));

        // Each entry retired, with its own lane, and far fewer entries than registrations.
        const registrations = thread_count * 200;
        var entry_count: usize = 0;
        var lanes_seen: [registrations]bool = @splat(false);
        var it = registry.first.load(.acquire);
        while (it) |entry| : (it = entry.next.load(.acquire)) {
            entry_count += 1;
            try std.testing.expectEqual(EntryState.retired, entry.state.load(.acquire));
            try std.testing.expect(!lanes_seen[entry.lane]);
            lanes_seen[entry.lane] = true;
        }
        try std.testing.expectEqual(@as(u32, @intCast(entry_count)), registry.lane_count.load(.monotonic));
        try std.testing.expect(entry_count >= 1 and entry_count < registrations / 4);
    }

    test "thread registry keeps atom bindings producer-local" {
        const allocator = std.testing.allocator;
        var registry = Registry{};
        defer registry.deinit(allocator);
        const buffer = try SpscRingBuffer.init(allocator, test_ring_bytes);
        defer buffer.deinit(allocator);
        try registry.append(allocator, buffer, 1, "first");
        try registry.append(allocator, buffer, 2, "second");

        // The registry borrows identities only; lookup is done by each producer.
        var first_atoms: Atom.Registry = undefined;
        var second_atoms: Atom.Registry = undefined;
        const first = registry.lookupThread(1).?;
        const second = registry.lookupThread(2).?;
        try std.testing.expect(first.atoms == null);
        first.atoms = &first_atoms;
        try std.testing.expect(second.atoms == null);
        second.atoms = &second_atoms;
        const first_again = registry.lookupThread(1).?;
        try std.testing.expectEqual(&first_atoms, first_again.atoms.?);
        first.atoms = null;
        try std.testing.expectEqual(&second_atoms, second.atoms.?);
    }
};

const test_ring_bytes = 128 * 1024;

const disk_buf_cap = 65536;

/// Whether records are also printed as text on the process's stdout: `stdout` prints each
/// log record as a line of ZON (zones and metadata are not printed), `disabled` prints
/// nothing. Under `zig build`, a test binary's stdout carries the test runner's binary
/// protocol, so anything logging from inside a test must use `.disabled`.
pub const ConsoleEcho = enum { stdout, disabled };

/// After `start`, only the writer thread touches `printer`, `disk_buf`, the file and the
/// history's writing side, until `stop` has joined it. From the registry it reads the list
/// and each entry's ring; it reads no entry's `atoms` or `thread_id`, and reaches no
/// Memory, Scope or Atoms state.
pub const BackgroundWriter = struct {
    /// What the writer writes the file, prints and sleeps through.
    io: std.Io,
    /// The threads whose rings it drains.
    registry: *Registry,
    /// Where zone records go besides the file, and the names and messages that go with them.
    history: *zones.History,
    /// Whether the profiler records: log messages join the history only then.
    recording: *const std.atomic.Value(bool),
    /// Each lane's name as last added to the history, by hash, so a thread that registers
    /// again under the same name adds nothing.
    lane_name_hashes: [256]u64 = @splat(0),
    /// Zone names already in the history: each loaded image writes its own once.
    zone_names_seen: std.AutoHashMapUnmanaged(u64, void) = .empty,
    /// Each scope tag's name, owned by the printer's allocator, so a name written again is
    /// kept once and two names sharing a tag, their hash, are caught.
    scope_names: std.AutoHashMapUnmanaged(u64, []const u8) = .empty,
    /// The log file, open from `init` to `stop`.
    file: std.Io.File,
    /// False once `stop` asks the thread to finish; it drains every ring once more first.
    running: std.atomic.Value(bool),
    /// The writer thread, from `start` to `stop`.
    thread: std.Thread = undefined,
    /// File bytes not yet written out.
    disk_buf: [disk_buf_cap]u8 = undefined,
    /// The bytes of `disk_buf` in use.
    disk_pos: usize = 0,
    /// Prints records for the console echo, and owns the allocator the writer's maps use.
    printer: decoder.RecordPrinter = undefined,
    /// Whether each record is also printed on stdout.
    console_echo: ConsoleEcho,
    /// Where warnings and errors go as lines for a person; none in a writer on its own. Set
    /// before the thread starts.
    notices: ?*Notices = null,

    /// What the writer keeps for the profiler besides the file: the `history` that zones, names
    /// and messages go to, and `recording`, whether log messages join it. Both must outlive the
    /// writer.
    pub const Profiling = struct { history: *zones.History, recording: *const std.atomic.Value(bool) };

    /// Creates the log file at `path`, replacing one there, and writes its header. No thread
    /// runs yet: `start` begins it. `printer_allocator` is used by the writer thread once
    /// started, and alone by it. `registry` must outlive the writer. On failure the file is
    /// closed and nothing is kept.
    pub fn init(io: std.Io, printer_allocator: std.mem.Allocator, registry: *Registry, profiling: Profiling, path: []const u8, console_echo: ConsoleEcho) !BackgroundWriter {
        const file = try std.Io.Dir.cwd().createFile(io, path, .{});

        var bw = BackgroundWriter{
            .io = io,
            .registry = registry,
            .history = profiling.history,
            .recording = profiling.recording,
            .file = file,
            .running = std.atomic.Value(bool).init(true),
            .printer = decoder.RecordPrinter.init(printer_allocator),
            .console_echo = console_echo,
        };
        errdefer {
            bw.printer.deinit();
            bw.file.close(io);
        }
        const fh = fmt.FileHeader{};
        bw.bufWrite(std.mem.asBytes(&fh));
        try bw.flush();
        return bw;
    }

    /// Starts the writer thread. `self` must not move until `stop`. Fails when the thread
    /// cannot be spawned; the caller then closes the file and frees the printer.
    pub fn start(self: *BackgroundWriter) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    /// Has the thread write whatever the rings still hold, joins it, writes out the last bytes,
    /// frees what the writer kept and closes the file. Call it once, after `start` succeeded
    /// and after every producer has stopped logging.
    pub fn stop(self: *BackgroundWriter) void {
        self.running.store(false, .release);
        self.thread.join();
        self.flush() catch {};
        self.zone_names_seen.deinit(self.printer.allocator);
        var scope_name_values = self.scope_names.valueIterator();
        while (scope_name_values.next()) |scope_name| self.printer.allocator.free(scope_name.*);
        self.scope_names.deinit(self.printer.allocator);
        self.printer.deinit();
        self.file.close(self.io);
    }

    /// How long the writer sleeps when it finds nothing to write: the first wait, doubled
    /// each empty pass up to the longest. Writers do not wake it, so the longest is how stale
    /// the profiler's history and the console may be while the engine sits idle.
    const first_wait_ns = std.time.ns_per_ms;
    const longest_wait_ns = 16 * std.time.ns_per_ms;

    fn run(self: *BackgroundWriter) void {
        var wait_ns: u64 = first_wait_ns;
        while (true) {
            const still_running = self.running.load(.acquire);
            var found_data = false;

            var it = self.registry.first.load(.acquire);
            while (it) |entry| : (it = entry.next.load(.acquire)) {
                found_data = self.drainBuffer(entry) or found_data;
            }

            if (!still_running and !found_data) break;
            if (found_data) {
                wait_ns = first_wait_ns;
                continue;
            }
            self.io.sleep(.fromNanoseconds(wait_ns), .awake) catch {};
            wait_ns = @min(wait_ns * 2, longest_wait_ns);
        }
    }

    fn drainBuffer(self: *BackgroundWriter, entry: *Entry) bool {
        var wrote_any = false;
        while (entry.buffer.readFront()) |payload| {
            self.writeRecord(entry.lane, payload);
            entry.buffer.consumeFront();
            wrote_any = true;
        }
        if (wrote_any) self.flush() catch {};
        return wrote_any;
    }

    fn writeRecord(self: *BackgroundWriter, lane: u16, payload: []const u8) void {
        // A zone goes to the history and the file, never to the console.
        if (zones.RingRecord.of(payload)) |zone| {
            self.fileWrite(payload);
            self.history.append(zone.historyRecord());
            return;
        }
        const metadata = decoder.metadataOf(payload);
        if (metadata) |named| {
            if (named.command == .tag_name and !self.keepScopeName(named)) return;
        }
        self.fileWrite(payload);
        if (metadata) |named| self.nameFromMetadata(named);
        if (self.recording.load(.acquire)) self.messageToHistory(lane, payload);
        if (self.notices) |notices| self.tellNotice(notices, payload);

        if (self.console_echo == .disabled) return;
        var line_buf: [4096]u8 = undefined;
        // Streaming: a positional writer starts at offset 0 for every record, so stdout
        // redirected to a file keeps only the last one.
        var sw = std.Io.File.stdout().writerStreaming(self.io, &line_buf);
        self.printer.printRecord(payload, &sw.interface) catch {};
        sw.flush() catch {};
    }

    /// A log record, but not a metadata one, joins the history's messages as a line of text.
    fn messageToHistory(self: *BackgroundWriter, lane: u16, payload: []const u8) void {
        var text: [zones.max_message_bytes]u8 = undefined;
        const line = decoder.messageOf(payload, &text) orelse return;
        self.history.appendMessage(.init(line.timestamp_ns, line.tag, lane, line.level, line.text));
    }

    /// A warning or an error joins the notices as a line under its scope's name.
    fn tellNotice(self: *BackgroundWriter, notices: *Notices, payload: []const u8) void {
        var text: [Notices.max_line_bytes]u8 = undefined;
        const line = decoder.messageOf(payload, &text) orelse return;
        if (line.level < notices.min_level) return;
        const scope_name = self.scope_names.get(line.tag) orelse "log";
        notices.add(scope_name, line.text);
    }

    fn fileWrite(self: *BackgroundWriter, payload: []const u8) void {
        const header = fmt.RecordHeader{
            .length = @intCast(payload.len),
            .crc32 = fmt.crc32(payload),
        };
        self.bufWrite(std.mem.asBytes(&header));
        self.bufWrite(payload);
    }

    /// True for a scope's name not yet kept, which it now keeps; false for one written again,
    /// as each loaded image and each sequencer startup writes its scopes' names. Panics when
    /// two names share a tag.
    fn keepScopeName(self: *BackgroundWriter, metadata: decoder.Metadata) bool {
        const allocator = self.printer.allocator;
        const seen = self.scope_names.getOrPut(allocator, metadata.id) catch
            std.debug.panic("log: out of memory keeping scope names", .{});
        if (seen.found_existing) {
            if (std.mem.eql(u8, seen.value_ptr.*, metadata.name)) return false;
            std.debug.panic(
                "log: the scopes '{s}' and '{s}' share the tag {d}, their names' hash; rename one",
                .{ seen.value_ptr.*, metadata.name, metadata.id },
            );
        }
        seen.value_ptr.* = allocator.dupe(u8, metadata.name) catch
            std.debug.panic("log: out of memory keeping scope names", .{});
        return true;
    }

    /// A scope's or a lane's name, from its metadata record, joins the history's names.
    fn nameFromMetadata(self: *BackgroundWriter, metadata: decoder.Metadata) void {
        switch (metadata.command) {
            .tag_name => self.history.addName(.scope, metadata.id, 0, metadata.name),
            .thread_name => {
                const lane = metadata.lane orelse return;
                const hash = std.hash.Wyhash.hash(0, metadata.name);
                if (lane < self.lane_name_hashes.len) {
                    if (self.lane_name_hashes[lane] == hash) return;
                    self.lane_name_hashes[lane] = hash;
                }
                self.history.addName(.lane, lane, 0, metadata.name);
            },
            .zone_name => {
                const seen = self.zone_names_seen.getOrPut(self.printer.allocator, metadata.id) catch
                    std.debug.panic("log: out of memory keeping zone names", .{});
                if (seen.found_existing) return;
                self.history.addName(.zone, metadata.id, metadata.scope, metadata.name);
            },
            .clock_anchor => {},
        }
    }

    fn bufWrite(self: *BackgroundWriter, data: []const u8) void {
        var remaining = data;
        while (remaining.len > 0) {
            const space = disk_buf_cap - self.disk_pos;
            if (space == 0) {
                self.flush() catch return;
                continue;
            }
            const n = @min(space, remaining.len);
            @memcpy(self.disk_buf[self.disk_pos..][0..n], remaining[0..n]);
            self.disk_pos += n;
            remaining = remaining[n..];
        }
    }

    fn flush(self: *BackgroundWriter) !void {
        if (self.disk_pos == 0) return;
        try self.file.writeStreamingAll(self.io, self.disk_buf[0..self.disk_pos]);
        self.disk_pos = 0;
    }
};
