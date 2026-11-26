//! Structured logging, and the profile zones that travel in the same stream.
//!
//! A file takes a scope, `const Log = mesha.log.scope("resources");`, and logs through it:
//! `Log.info("loaded", .{ .path = path, .bytes = size })`. A record is a level, the scope, a
//! key that says what happened and a value, usually an anonymous struct of facts; it is
//! encoded where it is logged (`log/record.zig`) into the calling thread's ring, and the log's
//! writer thread moves it to the file, `mesha.meshalog` (`log/format.zig`; print it with
//! `zig build meshalog-print`), and to the console when echo is on. Logging allocates nothing
//! and takes no lock. Nothing is dropped: a full ring, a record over `record.max_record_bytes`
//! or a thread that logs without `initThread` panics, saying what to change.
//!
//! A warning or an error is also a line for a person (`log/notices.zig`), which the text
//! editor system takes with `takeNotices` and keeps in `*Messages*`.
//!
//! A zone is a named span of time on one thread, for the profiler:
//! `const zone = Log.zone(Zone.load); defer zone.end();` where `Zone` is an enum the file
//! declares. Zones are written only while recording (`setRecording`), into the same rings,
//! and the writer keeps them in the zone history (`log/zones.zig`) that the profiler reads.
//!
//! The host owns the log: `init` and `deinit`, once, and `frameMark` each frame. Each plugin
//! image has its own copy of this file's state pointer, which the host fills through the
//! plugin's `plugin_bind_log` export (`bindSharedState`); after that a plugin logs as the host
//! does, from kernels or anywhere else, on threads the host registered. Before `init`, and in
//! tests and tools that never call it, logging and zones do nothing.
const std = @import("std");
const builtin = @import("builtin");
/// How a record is encoded where it is logged.
pub const record = @import("log/record.zig");
/// Zone records and the history the writer keeps of them for the profiler.
pub const zones = @import("log/zones.zig");
/// Reading records back: a log file's records, and a record as text.
pub const decoder = @import("log/decoder.zig");
/// The layout of a log file: its header and each record's.
pub const format = @import("log/format.zig");
const SpscRingBuffer = @import("log/buffer.zig").SpscRingBuffer;
const writer_mod = @import("log/writer.zig");
const Notices = @import("log/notices.zig").Notices;
const contract = @import("contract.zig");
const Atom = @import("atom.zig").Atom;
const memory_mod = @import("memory.zig");

/// Whether zones are compiled in. A build with `-Dprofile-enabled=false` makes every zone and
/// frame mark a no-op; log records are unaffected.
pub const zones_enabled = @import("profile_options").enabled;

const Registry = writer_mod.Registry;
const BackgroundWriter = writer_mod.BackgroundWriter;
/// Whether records are also printed as text on stdout.
pub const ConsoleEcho = writer_mod.ConsoleEcho;

/// How much a record matters, least first. The integer is what a record carries.
pub const Level = enum(u8) {
    /// Detail for following one piece of code step by step.
    trace = 0,
    /// What a developer wants while working on the code.
    debug = 1,
    /// What happened, in the ordinary course of a run.
    info = 2,
    /// Something went wrong and was coped with. Also told to the person, in `*Messages*`.
    warn = 3,
    /// Something failed. Also told to the person, in `*Messages*`.
    err = 4,
    /// A failure the run cannot continue from. A scope has no function that logs at this level;
    /// the decoder names it.
    fatal = 5,
};

/// The name of the private memory scope the log keeps its state, rings and history in.
pub const scope_name = "host.log";

/// What `init` sizes the log with.
pub const Options = struct {
    /// Whether the writer also prints each record as a line of text on stdout.
    console_echo: ConsoleEcho = .disabled,
    /// Bytes of each logging thread's ring. Nothing is dropped: a record that finds its
    /// thread's ring full panics, and the message says to make this larger.
    thread_ring_bytes: u32 = 10 * 1024 * 1024,
    /// Bytes of zone history the writer keeps for the profiler: 32 bytes a zone.
    zone_history_bytes: usize = 64 * 1024 * 1024,
    /// Lane, scope and zone names the history can hold; a full table panics.
    zone_names: u32 = 16 * 1024,
    /// Log messages the history keeps beside its zones while recording, 256 bytes each; the
    /// oldest is overwritten.
    zone_messages: u32 = 16 * 1024,
};

/// The tag of metadata records, which no scope has.
const metadata_tag: u32 = 0;

/// Lives in a private host scope, since logging outlasts every other user of Memory.
/// A logging thread uses no arena and no Scope or Memory record: `initThread` may run on
/// any thread, so rings and entries take the scope's direct backing, whose counters are
/// atomic. The printer's arena is writer-thread-only once the writer starts, and stays out
/// of the scope's arena list so a report on the main thread never reads it. Recording a
/// message allocates nothing.
const LogState = struct {
    scope: *memory_mod.Scope,
    registry: Registry,
    writer: BackgroundWriter,
    printer_arena: std.heap.ArenaAllocator,
    io: std.Io,
    thread_ring_bytes: u32,
    /// Whether zones and frame marks are written; producers check it at each begin.
    recording: std.atomic.Value(bool),
    /// Written by the writer thread alone; see `log/zones.zig` for its readers.
    history: zones.History,
    /// The warnings and errors a person is to be told; see `log/notices.zig`.
    notices: Notices,
};

var g_state: ?*LogState = null;

/// The host's log state as a plugin image sees it: a pointer to pass along, nothing more.
/// The host owns initialization, thread registration and shutdown, and outlives every plugin
/// that holds the pointer.
pub const SharedState = opaque {};

/// The host's log state, to hand to a plugin's `plugin_bind_log`; null before `init` and
/// after `deinit`.
pub fn sharedState() ?*SharedState {
    return @ptrCast(g_state);
}

/// Points this image's logger at the host's state: what a plugin's `plugin_bind_log` export
/// does with the pointer the loader passes it, so the plugin's records go to the host's rings
/// and file. Null unbinds. The host keeps nothing of the plugin's. A plugin must not call
/// `init` or `deinit`.
pub fn bindSharedState(state: ?*SharedState) void {
    g_state = @ptrCast(@alignCast(state));
}

test {
    _ = @import("log/buffer.zig");
    _ = @import("log/writer.zig");
    _ = @import("log/decoder.zig");
    _ = @import("log/zones.zig");
    _ = @import("log/notices.zig");
}

/// Monotonic nanoseconds since an arbitrary start: the time of every record and of profile
/// zones. Comparable across threads and images of one run, not across runs. Callable anywhere,
/// whether or not the log is running.
pub fn now() u64 {
    return switch (builtin.os.tag) {
        .windows => blk: {
            var counter: std.os.windows.LARGE_INTEGER = undefined;
            var frequency: std.os.windows.LARGE_INTEGER = undefined;
            _ = std.os.windows.ntdll.RtlQueryPerformanceCounter(&counter);
            _ = std.os.windows.ntdll.RtlQueryPerformanceFrequency(&frequency);
            break :blk @intCast(@divTrunc(@as(i128, counter) * std.time.ns_per_s, frequency));
        },
        else => blk: {
            var time: std.os.linux.timespec = undefined;
            _ = std.os.linux.clock_gettime(.MONOTONIC, &time);
            break :blk @intCast(time.sec * std.time.ns_per_s + time.nsec);
        },
    };
}

/// Wall-clock nanoseconds since the Unix epoch, for the anchor record only.
fn wallClockNs() u64 {
    return switch (builtin.os.tag) {
        .windows => blk: {
            const system_time = std.os.windows.ntdll.RtlGetSystemTimePrecise();
            const ticks: u64 = @intCast(system_time);
            // System time counts 100 ns ticks from 1601.
            const epoch_offset_ticks: u64 = 116_444_736_000_000_000;
            break :blk (ticks - epoch_offset_ticks) * 100;
        },
        else => blk: {
            var time: std.os.linux.timespec = undefined;
            _ = std.os.linux.clock_gettime(.REALTIME, &time);
            break :blk @intCast(time.sec * std.time.ns_per_s + time.nsec);
        },
    };
}

/// Starts the log: creates the file at `path` (replacing one there; relative to the working
/// directory), starts the writer thread, registers the calling thread as `main` and writes
/// the clock anchor. The host calls it once, before anything logs. The log's memory is a
/// private scope of `memory`, which must outlive `deinit`; `path` is not kept.
///
/// Fails with `error.AlreadyInitialized` when the log is running, or with the error of
/// opening the scope, allocating, creating the file or starting the thread; a failure
/// releases what it made, so `init` may be called again.
pub fn init(io: std.Io, memory: *memory_mod.Memory, path: []const u8, options: Options) !void {
    if (g_state != null) return error.AlreadyInitialized;
    const scope_atom = Atom.from(scope_name);
    const log_scope = try memory.openPrivateScope(scope_atom);
    errdefer _ = memory.releasePrivateScope(log_scope);
    const s = try log_scope.fixedAllocator().create(LogState);
    s.* = .{
        .scope = log_scope,
        .registry = .{},
        .writer = undefined,
        .printer_arena = std.heap.ArenaAllocator.init(log_scope.backingAllocator()),
        .io = io,
        .thread_ring_bytes = options.thread_ring_bytes,
        .recording = .init(false),
        .history = try zones.History.init(log_scope.backingAllocator(), options.zone_history_bytes, options.zone_names, options.zone_messages),
        .notices = undefined,
    };
    errdefer s.history.deinit(log_scope.backingAllocator());
    s.notices = try Notices.init(log_scope.backingAllocator(), io, @intFromEnum(Level.warn));
    errdefer s.notices.deinit(log_scope.backingAllocator());
    errdefer s.printer_arena.deinit();
    s.writer = try BackgroundWriter.init(io, s.printer_arena.allocator(), &s.registry, .{ .history = &s.history, .recording = &s.recording }, path, options.console_echo);
    s.writer.notices = &s.notices;
    s.writer.start() catch |err| {
        s.writer.printer.deinit();
        s.writer.file.close(io);
        return err;
    };
    errdefer s.writer.stop();
    g_state = s;
    errdefer g_state = null;

    try initThread("main");
    emitClockAnchor();
    emitTagName(metadata_tag, "command");
}

/// Stops the log: the writer writes what the rings still hold and is joined, the file is
/// closed and the log's memory released. Every other logging thread must have stopped. Does
/// nothing when the log is not running. The host's alone.
pub fn deinit() void {
    const s = g_state orelse return;
    s.writer.stop();
    const backing = s.scope.backingAllocator();
    var it = s.registry.first.load(.acquire);
    while (it) |entry| : (it = entry.next.load(.acquire)) {
        entry.buffer.deinit(backing);
    }
    s.registry.deinit(backing);
    s.history.deinit(backing);
    s.notices.deinit(backing);
    s.printer_arena.deinit();
    g_state = null;
    const log_scope = s.scope;
    const released = log_scope.memory.releasePrivateScope(log_scope);
    std.debug.assert(released);
}

/// Moves the warnings and errors logged since the last call into `out`, a line each
/// (`scope: key value`, ended by a line feed), as many whole lines as fit, and returns them as
/// a slice of `out`; the rest wait for the next call. For the frame's thread, which shows
/// them: the text editor system calls it each dispatch. Empty when the log is not running.
pub fn takeNotices(out: []u8) []u8 {
    const s = g_state orelse return out[0..0];
    return s.notices.take(out);
}

/// Has `wake` called, on the log's writer thread, each time a warning or an error is waiting
/// to be taken: the host's, to wake a frame loop that sleeps. `wake` must be safe to call from
/// that thread and must live until `deinit`.
pub fn setNoticeWake(wake: *const fn () void) void {
    const s = g_state orelse return;
    s.notices.wake.store(wake, .release);
}

/// Every thread that logs calls this first, on itself; logging from a thread that has not
/// panics. `name` names the thread in the log, its lane in the profiler, and a full ring's
/// panic; it is copied. `init` does it for the thread that calls `init`.
/// Fails with `error.DuplicateThread` when the thread is registered already, and
/// `error.OutOfMemory` when a ring of `Options.thread_ring_bytes` cannot be had. Does nothing
/// when the log is not running.
pub fn initThread(name: []const u8) !void {
    const s = g_state orelse return;
    try s.registry.register(s.scope.backingAllocator(), std.Thread.getCurrentId(), name, s.thread_ring_bytes);
    setThreadName(name);
}

/// Ends the calling thread's logging: it must log nothing after. Its ring, with whatever is
/// still unread in it, passes to the next thread that calls `initThread`.
pub fn deinitThread() void {
    const s = g_state orelse return;
    const thread_id = std.Thread.getCurrentId();
    if (s.registry.lookupThread(thread_id)) |entry| entry.retire();
}

/// Binds the interner whose names the calling thread's records carry: an `Atom` in a logged
/// value is written as its name when `atoms` holds it, and as its number otherwise. May be
/// called on the thread that owns the interner or on any other, since names are read with
/// `lookupShared`. Pass null (or call `deinitThread`) before destroying the interner. A record
/// holds a copy of the name's bytes, not a pointer.
pub fn setThreadAtoms(atoms: ?*Atom.Registry) void {
    const entry = getThread() orelse return;
    entry.atoms = atoms;
}

/// Names the calling thread, and its zones' lane, in the log, replacing the name `initThread`
/// gave. The thread must be registered; otherwise nothing happens.
pub fn setThreadName(name: []const u8) void {
    const entry = getThread() orelse return;
    const Cmd = struct { cmd: []const u8, id: u64, lane: u16, name: []const u8 };
    writeRecord(.info, 0, "log", "cmd", Cmd{
        .cmd = @tagName(record.MetadataCommand.thread_name),
        .id = std.Thread.getCurrentId(),
        .lane = entry.lane,
        .name = name,
    });
}

/// The logger of the scope `name`: a namespace of functions that log under it, and begin
/// zones in it. A scope is usually a system or a file; take it once at the top of the file,
/// `const Log = log.scope("panels");`. The name is written to the log the first time the
/// image logs through the scope. Its tag is `scopeTag(name)`, so two names must not share a
/// tag.
///
/// Each function takes a `key`, a short snake_case name of what happened, and a `value`:
/// anything `record.Encoder.writeValue` encodes, usually an anonymous struct. Slices are
/// copied into the record, so they may be temporary. An atom is written as its name when the
/// thread has an interner bound (`setThreadAtoms`) that holds it.
pub fn scope(comptime name: []const u8) type {
    return struct {
        const tag_id: u32 = blk: {
            @setEvalBranchQuota(1000 + 100 * name.len);
            break :blk scopeTag(name);
        };
        /// Whether this image has written the scope's name; one thread wins writing it.
        var named: bool = false;

        fn ensureRegistered() u32 {
            if (@atomicLoad(bool, &named, .acquire)) return tag_id;
            if (g_state == null) return tag_id;
            const won = @cmpxchgStrong(bool, &named, false, true, .acq_rel, .acquire) == null;
            if (won) emitTagName(tag_id, name);
            return tag_id;
        }

        /// Begins a zone named by a tag of the caller's zone enum, in this scope: the zone's
        /// system, which the profiler colors it by. The enum's names are written to the log on
        /// its first zone here. Returns at once with a zone that does nothing unless recording
        /// is on; otherwise the calling thread must be registered, and zones nest at most
        /// `zones.max_depth` deep, or it panics. End it with `Zone.end` on the same thread.
        pub fn zone(comptime zone_tag: anytype) Zone {
            if (!zones_enabled) return .{};
            const scope_tag = ensureRegistered();
            ZoneNames(@TypeOf(zone_tag)).ensure(scope_tag);
            const name_hash = comptime std.hash.Wyhash.hash(0, @tagName(zone_tag));
            return beginZone(scope_tag, name_hash);
        }

        /// Writes each tag of `E` as a zone name of this scope, once per loaded image.
        fn ZoneNames(comptime E: type) type {
            return struct {
                var written: bool = false;

                fn ensure(scope_tag: u32) void {
                    if (@atomicLoad(bool, &written, .acquire)) return;
                    if (g_state == null) return;
                    for (std.enums.values(E)) |value| registerZoneName(scope_tag, @tagName(value));
                    @atomicStore(bool, &written, true, .release);
                }
            };
        }

        /// Logs `key` and `value` at `Level.trace`.
        pub fn trace(key: []const u8, value: anytype) void {
            const scope_tag = ensureRegistered();
            writeRecord(.trace, scope_tag, name, key, value);
        }
        /// Logs `key` and `value` at `Level.debug`.
        pub fn debug(key: []const u8, value: anytype) void {
            const scope_tag = ensureRegistered();
            writeRecord(.debug, scope_tag, name, key, value);
        }
        /// Logs `key` and `value` at `Level.info`.
        pub fn info(key: []const u8, value: anytype) void {
            const scope_tag = ensureRegistered();
            writeRecord(.info, scope_tag, name, key, value);
        }
        /// Logs `key` and `value` at `Level.warn`; the person is also told, in `*Messages*`.
        pub fn warn(key: []const u8, value: anytype) void {
            const scope_tag = ensureRegistered();
            writeRecord(.warn, scope_tag, name, key, value);
        }
        /// Logs `key` and `value` at `Level.err`; the person is also told, in `*Messages*`.
        pub fn err(key: []const u8, value: anytype) void {
            const scope_tag = ensureRegistered();
            writeRecord(.err, scope_tag, name, key, value);
        }
    };
}

/// The tag of the scope named `name`: its name's hash, cut to 32 bits, and never the metadata
/// tag, 0. It needs no state, so any thread finds it at any time, comptime included. Two names
/// that share a tag panic the log's writer when the second is registered.
pub fn scopeTag(name: []const u8) u32 {
    const hash: u32 = @truncate(std.hash.Wyhash.hash(0, name));
    return if (hash == metadata_tag) 1 else hash;
}

/// Writes the name of a scope known only at run time, as a sequencer's systems are, and
/// returns its tag. Done at startup, by `sequencer.internNames`; registering again writes the
/// name again, which the writer keeps once. The calling thread must be registered.
pub fn registerScope(name: []const u8) u32 {
    const tag = scopeTag(name);
    if (g_state != null) emitTagName(tag, name);
    return tag;
}

// ---- zones ---------------------------------------------------------------------------

/// Starts or stops writing zones and frame marks, and keeping log messages in the zone
/// history. Zones begun before stopping still end and are written. Callable from any thread;
/// the profiler's record button and MCP's `profile_pause` are what call it.
pub fn setRecording(on: bool) void {
    const s = g_state orelse return;
    s.recording.store(on, .release);
}

/// Whether zones and frame marks are being written; false when the log is not running.
pub fn isRecording() bool {
    const s = g_state orelse return false;
    return s.recording.load(.acquire);
}

/// The zone history, for its readers (`zones.Reader`); see `log/zones.zig`. Null when the log
/// is not running. The pointer is valid until `deinit`.
pub fn zoneHistory() ?*zones.History {
    const s = g_state orelse return null;
    return &s.history;
}

/// A zone begun by `scope(...).zone` or `beginNamedZone`; `end` it on the same thread,
/// innermost first, usually with `defer zone.end();`. A default value is a zone that was not
/// recorded, whose `end` does nothing.
pub const Zone = struct {
    /// The calling thread's registry entry while the zone is recorded; null otherwise.
    entry: ?*writer_mod.Entry = null,

    /// Ends the zone and writes it, with its duration, to the calling thread's ring. Does
    /// nothing for a zone begun while not recording. A duration over about 4.3 seconds is
    /// clamped to that.
    pub fn end(zone: Zone) void {
        if (!zones_enabled) return;
        const entry = zone.entry orelse return;
        std.debug.assert(entry.zone_depth > 0);
        entry.zone_depth -= 1;
        const depth = entry.zone_depth;
        const open = entry.open_zones[depth];
        const elapsed = now() -| open.begin_ns;
        const duration: u32 = @intCast(@min(elapsed, std.math.maxInt(u32)));
        writeZoneRecord(entry, .{ .event = .zone, .lane = entry.lane, .depth = depth, .scope = open.scope, .duration_ns = duration, .name = open.name, .begin_ns = open.begin_ns });
    }
};

/// Names a zone for the history's readers: `name`'s hash, in the scope tagged `scope_tag`.
/// Zones named at run time (a sequencer's kernels and calls) are named this way at startup;
/// `scope(...).zone` names its enum's itself. Writes a record, so the calling thread must be
/// registered. `name` is copied.
pub fn registerZoneName(scope_tag: u32, name: []const u8) void {
    if (!zones_enabled) return;
    if (g_state == null) return;
    const ZoneName = struct { cmd: []const u8, id: u64, scope: u32, name: []const u8 };
    writeRecord(.info, 0, "log", "cmd", ZoneName{ .cmd = @tagName(record.MetadataCommand.zone_name), .id = zoneHash(name), .scope = scope_tag, .name = name });
}

/// A zone name's hash: the same as `Atom.from` gives the name.
pub fn zoneHash(name: []const u8) u64 {
    return std.hash.Wyhash.hash(0, name);
}

/// Begins a zone named at run time, as a sequencer's kernels are, in the scope tagged
/// `scope_tag`; its name is registered once with `registerZoneName`. Only the name's hash is
/// kept. Behaves as `scope(...).zone` does otherwise.
pub fn beginNamedZone(scope_tag: u32, name: []const u8) Zone {
    if (!zones_enabled) return .{};
    return beginZone(scope_tag, zoneHash(name));
}

/// Begins a zone whose name's hash is `name_hash`, in the scope tagged `scope_tag`, on the
/// calling thread, while recording. It is written when it ends.
fn beginZone(scope_tag: u32, name_hash: u64) Zone {
    if (!zones_enabled) return .{};
    const s = g_state orelse return .{};
    if (!s.recording.load(.monotonic)) return .{};
    const entry = getThread() orelse std.debug.panic("log: thread {d} begins a zone without log.initThread", .{std.Thread.getCurrentId()});
    const depth = entry.zone_depth;
    if (depth >= zones.max_depth) std.debug.panic("log: zones nest deeper than {d} on the '{s}' thread", .{ zones.max_depth, entry.threadName() });
    entry.open_zones[depth] = .{ .scope = scope_tag, .name = name_hash, .begin_ns = now() };
    entry.zone_depth = depth + 1;
    return .{ .entry = entry };
}

/// Ends the current frame and begins frame `index`, while recording. The host's main thread
/// calls it once per main-loop iteration; a plugin never does.
pub fn frameMark(index: u64) void {
    if (!zones_enabled) return;
    const s = g_state orelse return;
    if (!s.recording.load(.monotonic)) return;
    const entry = getThread() orelse std.debug.panic("log: thread {d} marks a frame without log.initThread", .{std.Thread.getCurrentId()});
    writeZoneRecord(entry, .{ .event = .frame, .lane = entry.lane, .name = index, .begin_ns = now() });
}

fn writeZoneRecord(entry: *writer_mod.Entry, zone_record: zones.RingRecord) void {
    if (entry.buffer.tryWrite(std.mem.asBytes(&zone_record))) return;
    const s = g_state.?;
    std.debug.panic(
        "log: the '{s}' thread's ring ({d} KiB) is full writing a zone; make the log's thread ring larger (log.Options.thread_ring_bytes, now {d})",
        .{ entry.threadName(), entry.buffer.capacity() / 1024, s.thread_ring_bytes },
    );
}

fn getThread() ?*writer_mod.Entry {
    const s = g_state orelse return null;
    const thread_id = std.Thread.getCurrentId();
    return s.registry.lookupThread(thread_id);
}

/// Writes a record to the calling thread's ring, or panics: nothing logged is dropped. With
/// no log state (tests, tools) it does nothing.
fn writeRecord(level: Level, tag: u32, scope_label: []const u8, key: []const u8, value: anytype) void {
    const s = g_state orelse return;
    const entry = getThread() orelse std.debug.panic(
        "log: thread {d} logs {s}.{s} without log.initThread",
        .{ std.Thread.getCurrentId(), scope_label, key },
    );
    const timestamp = now();
    const severity = @intFromEnum(level);
    const enc = record.encodeWithAtoms(entry.atoms, entry.thread_id.load(.monotonic), timestamp, severity, tag, key, value);
    if (enc.overflow) std.debug.panic(
        "log: record {s}.{s} is larger than the {d} bytes a record may have",
        .{ scope_label, key, record.max_record_bytes },
    );
    if (!entry.buffer.tryWrite(enc.slice())) std.debug.panic(
        "log: the '{s}' thread's ring ({d} KiB) is full writing {s}.{s}; make the log's thread ring larger (log.Options.thread_ring_bytes, now {d})",
        .{ entry.threadName(), entry.buffer.capacity() / 1024, scope_label, key, s.thread_ring_bytes },
    );
}

fn emitTagName(id: u32, name: []const u8) void {
    const TagEntry = struct { cmd: []const u8, id: u32, name: []const u8 };
    writeRecord(.info, 0, "log", "cmd", TagEntry{ .cmd = @tagName(record.MetadataCommand.tag_name), .id = id, .name = name });
}

/// Records carry monotonic time; this pairs it once with the wall clock, so a printer can
/// show wall time.
fn emitClockAnchor() void {
    const Anchor = struct { cmd: []const u8, monotonic_ns: u64, wall_clock_ns: u64 };
    const monotonic_ns = now();
    const wall_clock_ns = wallClockNs();
    writeRecord(.info, 0, "log", "cmd", Anchor{ .cmd = @tagName(record.MetadataCommand.clock_anchor), .monotonic_ns = monotonic_ns, .wall_clock_ns = wall_clock_ns });
}

const testing = std.testing;
const test_options: Options = .{ .thread_ring_bytes = 256 * 1024 };

fn logFromWorker(result: *?anyerror) void {
    initThread("worker") catch |err| {
        result.* = err;
        return;
    };
    scope("log_test").info("worker", .{ .value = @as(u32, 7) });
    deinitThread();
}

fn countEntries(registry: *Registry) usize {
    var count: usize = 0;
    var it = registry.first.load(.acquire);
    while (it) |entry| : (it = entry.next.load(.acquire)) count += 1;
    return count;
}

test "failed logger init releases only its own work and init can retry" {
    var memory: memory_mod.Memory = undefined;
    memory.init(testing.allocator);
    defer memory.deinit();
    const survivor = try memory.openPrivateScope(Atom.from("survivor"));
    _ = try survivor.fixedAllocator().alloc(u8, 64);
    const survivor_pages = survivor.stats().backing.current_bytes;

    try testing.expectError(error.FileNotFound, init(testing.io, &memory, "missing_log_dir/run.meshalog", .{}));
    try testing.expect(sharedState() == null);
    try testing.expectEqual(@as(usize, 1), memory.scopes.items.len);
    try testing.expectEqual(survivor_pages, survivor.stats().backing.current_bytes);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(testing.io, &path_buf);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/run.meshalog", .{path_buf[0..path_len]});
    defer testing.allocator.free(path);
    try init(testing.io, &memory, path, test_options);
    try testing.expectEqual(@as(usize, 2), memory.scopes.items.len);
    deinit();
    try testing.expectEqual(@as(usize, 1), memory.scopes.items.len);
    try testing.expect(sharedState() == null);
}

test "a scope's tag is its name's hash, and registering it again names it once in the history" {
    var memory: memory_mod.Memory = undefined;
    memory.init(testing.allocator);
    defer memory.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(testing.io, &path_buf);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/tags.meshalog", .{path_buf[0..path_len]});
    defer testing.allocator.free(path);
    try init(testing.io, &memory, path, test_options);
    defer deinit();

    const first = registerScope("plugin_scope");
    try testing.expectEqual(first, scopeTag("plugin_scope"));
    try testing.expectEqual(first, scope("plugin_scope").tag_id);
    try testing.expect(first != scopeTag("other_scope"));
    for (0..1000) |_| try testing.expectEqual(first, registerScope("plugin_scope"));
    // Written after the repeats, on the same ring, so the writer has read them all once
    // this name is in the history.
    const last = registerScope("last_scope");

    const history = zoneHistory().?;
    var plugin_scope_names: usize = 0;
    var last_named = false;
    // The writer sleeps between looks while it finds nothing, up to a few milliseconds.
    for (0..2_000) |_| {
        plugin_scope_names = 0;
        for (history.publishedNames()) |*entry| {
            if (entry.kind != .scope) continue;
            if (entry.key == first) plugin_scope_names += 1;
            if (entry.key == last) last_named = true;
        }
        if (last_named) break;
        testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
    }
    try testing.expect(last_named);
    try testing.expectEqual(@as(usize, 1), plugin_scope_names);
}

test "threads register from their own thread and reuse a finished thread's ring" {
    var memory: memory_mod.Memory = undefined;
    memory.init(testing.allocator);
    defer memory.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path_len = try tmp.dir.realPath(testing.io, &path_buf);
    const path = try std.fmt.allocPrint(testing.allocator, "{s}/threads.meshalog", .{path_buf[0..path_len]});
    defer testing.allocator.free(path);
    try init(testing.io, &memory, path, test_options);
    defer deinit();
    const state = g_state.?;

    for (0..3) |_| {
        var result: ?anyerror = null;
        const worker = try std.Thread.spawn(.{}, logFromWorker, .{&result});
        worker.join();
        if (result) |err| return err;
        // The main thread's and one worker's: sequential workers share a retired entry.
        try testing.expectEqual(@as(usize, 2), countEntries(&state.registry));
    }
}
