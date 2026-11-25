//! The profiler system's contract: the requests a view of the profile sends and the snapshot it
//! gets back. The runtime is `runtime/profiler.zig`; the editor's Profiler panel is its user.
//!
//! Zones are recorded into the log's zone history (`core/log/zones.zig`) while recording is on;
//! this system reads that history, or a log file's, through a reader of its own. A view asks for a
//! `snapshot` of the frames it shows by pushing a row to `commands.profiler` (`request`), and the
//! host answers the latest such request with a `SnapshotMsg` in the asker's inbox. The `Snapshot`
//! it points at is a copy the host owns: three rotate, so it stays valid until two more snapshots
//! have been built and a view can keep drawing from the one it received while the next is built.
//!
//! `pause`, `record`, `truncate_after`, `load_file` and `show_live` move what the reader shows.
//! Recording and pausing switch the log's recording of zones on and off for the whole engine.

const std = @import("std");
const log = @import("../core/log.zig");
/// The log's zone history and its reader (`core/log/zones.zig`), which a `Snapshot` names zones
/// with.
pub const zones = log.zones;
const memory_mod = @import("../core/memory.zig");
const Table = @import("../core/table.zig");
const sequencer = @import("../core/sequencer.zig");

/// A zone as snapshots carry it: its name's hash, when it began in monotonic nanoseconds, how long
/// it took, its scope, its depth among the zones around it and its thread's lane.
pub const Record = zones.Record;

/// A request to the profiler, a row of `commands.profiler`. The host applies the rows in order
/// after each dispatch.
pub const CmdPayload = union(enum) {
    /// Builds a snapshot of the finished frames `first_frame` to `last_frame` and sends it to
    /// `reply` as a `SnapshotMsg`, at the next delivery. Both 0 means the latest finished frame. A
    /// nonzero `series_name`, a zone name's hash, also totals the main thread's zones of that name
    /// in every held frame; see `Snapshot.series`. Only the latest request is answered: one applied
    /// before an earlier one was delivered replaces it.
    snapshot: struct { first_frame: u64, last_frame: u64, reply: sequencer.ReplyTo, series_name: u64 = 0 },
    /// True stops recording zones and false resumes it, keeping what was recorded; the engine keeps
    /// running. Ignored while a log file is shown.
    pause: bool,
    /// True starts a recording, forgetting the last; false stops recording and keeps it. Either way
    /// a log file being shown gives way to what is recorded.
    record: bool,
    /// Forgets the frames after the frame of this index, so recording can go on from it. A log
    /// file's frames are kept: nothing records after them.
    truncate_after: u64,
    /// Shows the log file at `path` in place of what is being recorded: its frames, zones and
    /// messages, held to scrub. A file that cannot be read is logged and nothing changes but
    /// `Snapshot.load_failure`.
    load_file: []const u8,
    /// Goes back from a log file to what is being recorded.
    show_live,
};

/// The table the profiler's requests are pushed to.
pub const commands_table_name = "commands.profiler";
/// `commands.profiler` as a typed command table: `Requests.of(...)` pushes and reads `CmdPayload`
/// rows.
pub const Requests = sequencer.Commands(CmdPayload);

/// Asks the profiler for `command`, a row of `commands.profiler` the host applies after the
/// dispatch. `commands.profiler` must exist: the host makes it at start. A journaled system that
/// asks declares the table written, so a fault takes its request back.
pub fn request(memory: *memory_mod.Memory, tables: *Table.Registry, command: CmdPayload) void {
    Requests.of(memory, tables, commands_table_name).push(command);
}

/// The payload of the message that answers a `snapshot` request.
pub const SnapshotMsg = struct {
    /// Host-owned; valid until two more snapshots have been built.
    snapshot: *const Snapshot,
};

/// A frame of the main thread, in monotonic nanoseconds.
pub const FrameSpan = struct {
    /// The frame's number, as `first_frame` and `last_frame` name it.
    index: u64,
    /// When the frame began.
    begin_ns: u64,
    /// When the frame ended.
    end_ns: u64,

    /// How long the frame took, in nanoseconds; 0 when it ends before it begins.
    pub fn durationNs(frame: FrameSpan) u64 {
        return frame.end_ns -| frame.begin_ns;
    }
};

/// A log message in the window, as snapshots carry it.
pub const Message = struct {
    /// When it was logged, in monotonic nanoseconds.
    begin_ns: u64,
    /// Its scope: the system that logged it.
    scope: u32,
    /// Its severity.
    level: log.Level,
    /// The key and value as one line; the snapshot's memory.
    text: []const u8,
};

/// One thread's zones and messages in the window. Zones are one list per depth, each in begin
/// order; zones at one depth never overlap, so each list is ordered by end too.
pub const Lane = struct {
    /// The thread's name; host memory that outlives the snapshot.
    name: []const u8,
    /// The thread's zones, one list per depth, `depths[0]` the outermost. The snapshot's memory.
    depths: []const []const Record,
    /// The thread's log messages in the window, in time order.
    messages: []const Message = &.{},
};

/// One zone name's totals in one frame.
pub const ZoneTotals = struct {
    /// How many zones of the name the frame holds.
    count: u32 = 0,
    /// Their durations added, in nanoseconds.
    total_ns: u64 = 0,
    /// The time not spent in zones nested directly in them.
    self_ns: u64 = 0,
    /// The longest of them, in nanoseconds.
    max_ns: u64 = 0,
};

/// Why a log file was not loaded.
pub const LoadFailure = enum(u8) {
    /// No file was refused.
    none,
    /// It could not be read, or is not a log file.
    unreadable,
    /// It holds no zones: it was written while the profiler was not recording.
    no_zones,
};

/// What a view of the profile draws: the frames the history holds, and the zones and messages of a
/// window of them, by thread. Everything it points at is the host's and lasts as the snapshot does
/// (see `SnapshotMsg.snapshot`), but for `names` and each lane's `name`, which last longer.
pub const Snapshot = struct {
    /// Whether zones were not being recorded when the snapshot was built.
    paused: bool,
    /// The frames are a log file's, not what is being recorded.
    from_file: bool = false,
    /// Why the last log file asked for was not loaded, until one loads or recording starts.
    load_failure: LoadFailure = .none,
    /// Every finished frame the history still holds, oldest first.
    frames: []const FrameSpan,
    /// The most severe log message in each of `frames`: 0 for none, else its level plus one.
    frame_message_levels: []const u8 = &.{},
    /// The index of the first frame the window covers. It and `last_frame` are 0, and the window
    /// empty, when the history holds none of the frames asked for.
    first_frame: u64,
    /// The index of the last frame the window covers.
    last_frame: u64,
    /// When the window begins: its first frame's begin, in monotonic nanoseconds.
    begin_ns: u64,
    /// When the window ends: its last frame's end.
    end_ns: u64,
    /// The window's zones and messages, a lane for each thread that has any, in the order of the
    /// threads' lanes in the log (`Record.lane`).
    lanes: []const Lane,
    /// Zones left out because the window held more than a snapshot copies, or were
    /// overwritten while it was copied.
    truncated: bool,
    /// The requested zone name's totals in each of `frames`, on the main thread; empty when
    /// none was asked for.
    series: []const ZoneTotals = &.{},
    /// The zone name `series` totals, as the request gave it; 0 for none.
    series_name: u64 = 0,
    /// The profiler's reader, which names zones and scopes; it outlives every snapshot.
    names: *const zones.Reader,

    /// The text of the zone name whose hash is `name`, or `?` for one the reader has not seen. The
    /// reader's memory.
    pub fn zoneName(snapshot: *const Snapshot, name: u64) []const u8 {
        return snapshot.names.zoneName(name) orelse "?";
    }

    /// The scope a zone name belongs to: its system, which its colour follows. 0 for a name the
    /// reader has not seen.
    pub fn zoneScope(snapshot: *const Snapshot, name: u64) u32 {
        return snapshot.names.zoneScope(name) orelse 0;
    }

    /// The text of the scope `scope`, or `?` for one the reader has not seen. The reader's memory.
    pub fn scopeName(snapshot: *const Snapshot, scope: u32) []const u8 {
        return snapshot.names.scopeName(scope) orelse "?";
    }
};
