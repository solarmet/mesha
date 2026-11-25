//! Profile zones in the log stream, and the history the log's writer keeps of them.
//!
//! A zone is a named span of time on one thread; zones nest. A producer writes a finished
//! zone as one fixed-size record into its thread's log ring, as it writes a log record, and
//! the main thread marks each frame the same way. The log's writer thread, the rings' only
//! reader, copies each into the **history**: a ring of fixed-size records it alone writes,
//! which overwrites its oldest record when full. Readers (the profiler system, for the panel,
//! and the MCP server) read it without making the writer wait:
//!
//! - the writer stores a record's words atomically, then publishes `written`, the count of
//!   records ever written, with release;
//! - a reader loads `written` with acquire, copies the records it wants word by word with
//!   atomic loads, then reads `written` again, through a read-modify-write that orders the
//!   copy before it, and keeps only the records the writer cannot have overwritten since.
//!
//! The writer also keeps the **names**: an append-only table of lane (thread), scope and
//! zone names, each entry written whole before the count that publishes it.
//!
//! Log messages written while recording go into a second ring beside the zones, the
//! **messages**, a line of text each, so the profiler can place them on its timeline. It is
//! written and read by the same protocol as the zones, with its own count.
const std = @import("std");
const Atom = @import("../atom.zig").Atom;

/// The first byte of a zone record in a log ring or file. A log record begins with its
/// six-element array header (0x96); 0xc1 is the one byte the record encoding never uses.
pub const record_kind: u8 = 0xc1;

/// Zones nest at most this deep on one thread.
pub const max_depth = 64;

/// What a record marks: `zone`, a finished span of time on a thread, or `frame`, the moment
/// the main thread began a frame.
pub const Event = enum(u8) { zone = 0, frame = 1 };

/// A zone or frame mark as a producer writes it to its ring, and as the log file holds it: 32
/// bytes, in the byte order of the machine that wrote it.
pub const RingRecord = extern struct {
    /// `record_kind`, which tells a zone record from a log record.
    kind: u8 = record_kind,
    /// Whether this is a zone or a frame mark.
    event: Event,
    /// The writing thread's lane, as its registry entry gives it.
    lane: u16,
    /// How many zones were open on the thread when this one began: 0 for an outermost zone.
    depth: u16 = 0,
    /// Zero.
    reserved: u16 = 0,
    /// The tag of the scope the zone was begun in; 0 for a frame mark.
    scope: u32 = 0,
    /// How long the zone lasted, in nanoseconds: up to about 4.3 seconds; a longer zone is
    /// clamped. 0 for a frame mark.
    duration_ns: u32 = 0,
    /// A zone's name hash, or a frame's index.
    name: u64,
    /// When the zone began or the frame was marked, in monotonic nanoseconds (`log.now`).
    begin_ns: u64,

    /// The record as the history keeps it: the same facts, without the kind byte.
    pub fn historyRecord(record: RingRecord) Record {
        return .{ .name = record.name, .begin_ns = record.begin_ns, .duration_ns = record.duration_ns, .scope = record.scope, .depth = record.depth, .lane = record.lane, .event = record.event };
    }

    /// The zone record `payload` holds, copied out; null when `payload` is not exactly one zone
    /// record, as a log record is not.
    pub fn of(payload: []const u8) ?RingRecord {
        if (payload.len != @sizeOf(RingRecord) or payload[0] != record_kind) return null;
        var record: RingRecord = undefined;
        @memcpy(std.mem.asBytes(&record), payload);
        return record;
    }
};

/// A zone or frame mark in the history. 32 bytes, four words.
pub const Record = extern struct {
    /// A zone's name hash (`Atom.from` of its name), or a frame's index.
    name: u64,
    /// When the zone began or the frame was marked, in monotonic nanoseconds (`log.now`).
    begin_ns: u64,
    /// How long the zone lasted, in nanoseconds, up to about 4.3 seconds. 0 for a frame mark.
    duration_ns: u32,
    /// The tag of the scope the zone was begun in; 0 for a frame mark.
    scope: u32 = 0,
    /// How many zones were open on the thread when this one began: 0 for an outermost zone.
    depth: u16,
    /// The writing thread's lane: its entry's place in the log's registry.
    lane: u16 = 0,
    /// Whether this is a zone or a frame mark.
    event: Event = .zone,
    /// Zero.
    reserved: [3]u8 = @splat(0),

    /// When the zone ended, in monotonic nanoseconds: its begin plus its duration.
    pub fn endNs(record: Record) u64 {
        return record.begin_ns + record.duration_ns;
    }

    /// The zone's name hash as an atom. Zone names hash as atoms do, so a name the interner
    /// holds can be looked up; meaningless for a frame mark.
    pub fn nameAtom(record: Record) Atom {
        return @enumFromInt(record.name);
    }
};

comptime {
    std.debug.assert(@sizeOf(RingRecord) == 32);
    std.debug.assert(@sizeOf(Record) == 32);
}

const Words = [4]u64;

/// The longest text a message keeps; a longer one is cut short.
pub const max_message_bytes = 232;

/// A log message in the history: when, on which lane, at which level and in which scope,
/// and its key and value as one line. 256 bytes, 32 words.
pub const Message = extern struct {
    /// When the message was logged, in monotonic nanoseconds (`log.now`).
    begin_ns: u64,
    /// The tag of the scope that logged it.
    scope: u32,
    /// The lane of the thread that logged it.
    lane: u16,
    /// The log's `Level`, as its integer.
    level: u8,
    /// The bytes of `text_bytes` in use.
    len: u8,
    /// Zero.
    reserved: [8]u8 = @splat(0),
    /// The text, zero-filled after `len`; read it with `text`.
    text_bytes: [max_message_bytes]u8,

    /// The message's line, the record's key then its value: a slice of this message.
    pub fn text(message: *const Message) []const u8 {
        return message.text_bytes[0..message.len];
    }

    /// A message of `text_value`, copied and cut short to `max_message_bytes`. `level` is a
    /// `log.Level` integer and `begin_ns` monotonic nanoseconds.
    pub fn init(begin_ns: u64, scope: u32, lane: u16, level: u8, text_value: []const u8) Message {
        var message: Message = .{ .begin_ns = begin_ns, .scope = scope, .lane = lane, .level = level, .len = 0, .text_bytes = undefined };
        const kept = text_value[0..@min(text_value.len, max_message_bytes)];
        @memcpy(message.text_bytes[0..kept.len], kept);
        @memset(message.text_bytes[kept.len..], 0);
        message.len = @intCast(kept.len);
        return message;
    }
};

const MessageWords = [@sizeOf(Message) / 8]u64;

comptime {
    std.debug.assert(@sizeOf(Message) == 256);
}

/// What a names entry names: a `lane` (a thread, by its index), a `scope` (by its tag) or a
/// `zone` (by its name's hash).
pub const NameKind = enum(u8) { lane, scope, zone };

/// The longest name a names entry keeps.
pub const max_name_bytes = 64;

/// One name in the history's names table. Never changes once published.
pub const NameEntry = struct {
    /// What `key` identifies.
    kind: NameKind,
    /// A lane's index, a scope's tag, or a zone's name hash.
    key: u64,
    /// A zone's scope; 0 otherwise.
    scope: u32 = 0,
    /// The bytes of `text` in use.
    len: u8,
    /// The name's bytes, cut to `max_name_bytes`; read them with `name`.
    text: [max_name_bytes]u8,

    /// The name: a slice of this entry, valid as long as the history.
    pub fn name(entry: *const NameEntry) []const u8 {
        return entry.text[0..entry.len];
    }
};

/// What the log's writer keeps for the profiler: a ring of zone and frame records, a ring of
/// log messages, and the table of names. One thread writes it (`append`, `appendMessage`,
/// `addName`); any number read it (`copy`, `copyMessage`, `publishedNames`, the counts)
/// without locks. Records and messages are numbered from 0 in the order written, and a
/// number's slot is reused once `capacity()` later ones (or the messages' count) exist.
pub const History = struct {
    /// The zone and frame records' ring, a record per slot.
    records: []Words,
    /// Records ever written: the number of the next one.
    written: std.atomic.Value(u64) = .init(0),
    /// The names table; only the first `names_count` entries are published.
    names: []NameEntry,
    /// The names published so far.
    names_count: std.atomic.Value(u32) = .init(0),
    /// The messages' ring, a message per slot.
    messages: []MessageWords,
    /// Messages ever written: the number of the next one.
    messages_written: std.atomic.Value(u64) = .init(0),

    /// A history with `record_bytes` of zone records (32 bytes each), room for `name_count`
    /// names and the latest `message_count` messages (at least one), all allocated from
    /// `allocator` at once: nothing is allocated after. `record_bytes` must be at least 32.
    pub fn init(allocator: std.mem.Allocator, record_bytes: usize, name_count: u32, message_count: u32) !History {
        const records = try allocator.alloc(Words, record_bytes / @sizeOf(Words));
        errdefer allocator.free(records);
        const names = try allocator.alloc(NameEntry, name_count);
        errdefer allocator.free(names);
        const messages = try allocator.alloc(MessageWords, @max(message_count, 1));
        return .{ .records = records, .names = names, .messages = messages };
    }

    /// Frees the rings and the names; `allocator` is the one given to `init`. No thread may
    /// still write or read.
    pub fn deinit(history: *History, allocator: std.mem.Allocator) void {
        allocator.free(history.records);
        allocator.free(history.names);
        allocator.free(history.messages);
    }

    /// Adds a message, overwriting the oldest when the ring is full. The writer's alone.
    pub fn appendMessage(history: *History, message: Message) void {
        const number = history.messages_written.load(.monotonic);
        const words: MessageWords = @bitCast(message);
        const slot = &history.messages[number % history.messages.len];
        for (slot, words) |*word, value| @atomicStore(u64, word, value, .monotonic);
        history.messages_written.store(number + 1, .release);
    }

    /// Messages ever written, as a reader sees them.
    pub fn messagesWrittenCount(history: *const History) u64 {
        return history.messages_written.load(.acquire);
    }

    /// Copies message `number` into `out`; false, with `out` untouched, when the writer may
    /// have overwritten it, before or during the copy. `number` must be below
    /// `messagesWrittenCount()`. Any thread's; never waits.
    pub fn copyMessage(history: *History, number: u64, out: *Message) bool {
        const slot = &history.messages[number % history.messages.len];
        var words: MessageWords = undefined;
        for (&words, slot) |*word, *source| word.* = @atomicLoad(u64, source, .monotonic);
        // As in `copy`: orders the loads above before this read of the count.
        const written_after = history.messages_written.fetchAdd(0, .acq_rel);
        if (number < written_after -| history.messages.len) return false;
        out.* = @bitCast(words);
        return true;
    }

    /// How many zone and frame records the history holds before it overwrites the oldest.
    pub fn capacity(history: *const History) u64 {
        return history.records.len;
    }

    /// Adds a zone or frame record, overwriting the oldest when the ring is full. The
    /// writer's alone.
    pub fn append(history: *History, record: Record) void {
        const number = history.written.load(.monotonic);
        const words: Words = @bitCast(record);
        const slot = &history.records[number % history.records.len];
        for (slot, words) |*word, value| @atomicStore(u64, word, value, .monotonic);
        history.written.store(number + 1, .release);
    }

    /// Adds a name: `key` is a lane's index, a scope's tag or a zone's name hash, as `kind`
    /// says, and `scope` a zone's scope tag (0 otherwise). `text` is copied, cut to
    /// `max_name_bytes`. Nothing is dropped: a full table panics, saying what to make larger.
    /// The writer's alone.
    pub fn addName(history: *History, kind: NameKind, key: u64, scope: u32, text: []const u8) void {
        const count = history.names_count.load(.monotonic);
        if (count >= history.names.len) std.debug.panic(
            "log: the zone history's names table ({d} names) is full adding '{s}'; make it larger (log.Options.zone_names)",
            .{ history.names.len, text },
        );
        const kept = text[0..@min(text.len, max_name_bytes)];
        const entry = &history.names[count];
        entry.* = .{ .kind = kind, .key = key, .scope = scope, .len = @intCast(kept.len), .text = undefined };
        @memcpy(entry.text[0..kept.len], kept);
        history.names_count.store(count + 1, .release);
    }

    /// Records ever written, as a reader sees them.
    pub fn writtenCount(history: *const History) u64 {
        return history.written.load(.acquire);
    }

    /// The names published so far; entries never change once published, so the slice and
    /// what it holds stay valid as long as the history. Any thread's.
    pub fn publishedNames(history: *const History) []const NameEntry {
        const count = history.names_count.load(.acquire);
        return history.names[0..count];
    }

    /// Copies records `first` up to, not including, `end` into `out` (one per number,
    /// `out[0]` being `first`) and returns the first number whose copy is sound: a record the
    /// writer may have overwritten before or during the copy is not, and its slot of `out`
    /// holds garbage. `end` must not pass `writtenCount()`, and `out` must hold `end - first`.
    /// Any thread's; never waits.
    pub fn copy(history: *History, first: u64, end: u64, out: []Record) u64 {
        std.debug.assert(out.len >= end - first);
        for (out[0 .. end - first], first..) |*record, number| {
            const slot = &history.records[number % history.records.len];
            var words: Words = undefined;
            for (&words, slot) |*word, *source| word.* = @atomicLoad(u64, source, .monotonic);
            record.* = @bitCast(words);
        }
        // A read-modify-write with release orders the loads above before this read of the
        // count; any slot the writer reached since then may hold a newer record.
        const written_after = history.written.fetchAdd(0, .acq_rel);
        const sound_from = written_after -| history.records.len;
        return @max(first, sound_from);
    }
};

/// A frame of the main thread, from its mark to the next, as a `Reader` indexes it. Times are
/// monotonic nanoseconds.
pub const Frame = struct {
    /// The frame's number, as `log.frameMark` was given it.
    index: u64,
    /// When its mark was written, in monotonic nanoseconds.
    begin_ns: u64,
    /// 0 while the frame is the latest.
    end_ns: u64 = 0,
    /// History numbers bounding the records that begin in the frame, on any lane.
    first_number: u64,
    /// One past the highest history number among the frame's records.
    end_number: u64,
};

/// What a reader knows of the history: the frames it has indexed, the messages, and the
/// names. It reads the history only through its copying functions, so it never makes the
/// writer wait. Call `update` to take in what was written since the last call, then ask for
/// frames (`finishedFrames`), the zones in them (`zonesIn`) and the messages (`messagesIn`).
/// One thread uses a reader; each reader has its own view, and several may read one history.
pub const Reader = struct {
    /// The history read; it must outlive the reader.
    history: *History,
    /// Allocates the reader's lists and maps.
    allocator: std.mem.Allocator,
    /// The next record number to index.
    indexed: u64,
    /// The frames indexed and still whole in the history, oldest first; the last may be
    /// unfinished.
    frames: std.ArrayList(Frame) = .empty,
    /// The numbers and begin times of records indexed into the latest frame, which the next
    /// frame's mark may claim.
    latest: std.ArrayList(struct { number: u64, begin_ns: u64 }) = .empty,
    /// How many of the history's names have been read into the maps below.
    names_read: u32 = 0,
    /// Each lane's name by lane index, `thread` where none was given; slices of the history's
    /// names table.
    lane_names: std.ArrayList([]const u8) = .empty,
    /// Each scope tag's name; slices of the history's names table.
    scope_names: std.AutoHashMapUnmanaged(u32, []const u8) = .empty,
    /// Entries of the history's names table, which never move.
    zone_names: std.AutoHashMapUnmanaged(u64, *const NameEntry) = .empty,
    /// Where records are copied to while indexing and visiting.
    scratch: std.ArrayList(Record) = .empty,
    /// The next message number to index.
    messages_indexed: u64,
    /// The messages indexed and not yet overwritten, in the order they were written: each
    /// lane's in time order, the lanes' interleaved as the writer drained them.
    messages: std.ArrayList(IndexedMessage) = .empty,

    /// What the reader keeps of a message: its `number` in the history, to copy its text from,
    /// and its `begin_ns`, `lane` and `level` (a `log.Level` integer) to place it by.
    pub const IndexedMessage = struct { number: u64, begin_ns: u64, lane: u16, level: u8 };

    /// A reader of `history` that indexes the records and messages written from now on.
    /// Allocates nothing yet; `allocator` is kept for `update` and freed from by `deinit`.
    pub fn init(history: *History, allocator: std.mem.Allocator) Reader {
        return .{ .history = history, .allocator = allocator, .indexed = history.writtenCount(), .messages_indexed = history.messagesWrittenCount() };
    }

    /// Frees what the reader allocated. The history is untouched.
    pub fn deinit(reader: *Reader) void {
        reader.frames.deinit(reader.allocator);
        reader.latest.deinit(reader.allocator);
        reader.lane_names.deinit(reader.allocator);
        reader.scope_names.deinit(reader.allocator);
        reader.zone_names.deinit(reader.allocator);
        reader.scratch.deinit(reader.allocator);
        reader.messages.deinit(reader.allocator);
    }

    /// Forgets every frame and message; indexing goes on from what is written from now on.
    pub fn clear(reader: *Reader) void {
        reader.frames.clearRetainingCapacity();
        reader.latest.clearRetainingCapacity();
        reader.indexed = reader.history.writtenCount();
        reader.messages.clearRetainingCapacity();
        reader.messages_indexed = reader.history.messagesWrittenCount();
    }

    /// Forgets the frames after the frame whose index is `frame_index` and finishes that
    /// frame at the present moment if it was still open, so the next mark begins the frame
    /// after it. Does nothing when the reader has no such frame.
    pub fn truncateAfter(reader: *Reader, frame_index: u64) void {
        for (reader.frames.items, 0..) |*frame, position| {
            if (frame.index != frame_index) continue;
            if (frame.end_ns == 0) frame.end_ns = @import("../log.zig").now();
            reader.frames.shrinkRetainingCapacity(position + 1);
            reader.latest.clearRetainingCapacity();
            return;
        }
    }

    /// The frames that have finished and are still whole in the history, as of the last
    /// `update`, oldest first. The slice is the reader's, valid until its next `update`,
    /// `clear` or `truncateAfter`.
    pub fn finishedFrames(reader: *const Reader) []const Frame {
        const frames = reader.frames.items;
        if (frames.len == 0) return frames;
        const last_finished = frames[frames.len - 1].end_ns != 0;
        return if (last_finished) frames else frames[0 .. frames.len - 1];
    }

    /// The name of the thread on `lane`, or `thread` when the reader has read none for it.
    /// Valid as long as the history.
    pub fn laneName(reader: *const Reader, lane: u16) []const u8 {
        if (lane >= reader.lane_names.items.len) return "thread";
        return reader.lane_names.items[lane];
    }

    /// The name of the scope tagged `scope`, or null when the reader has read none. Valid as
    /// long as the history.
    pub fn scopeName(reader: *const Reader, scope: u32) ?[]const u8 {
        return reader.scope_names.get(scope);
    }

    /// The name whose hash is `name`, a zone record's `name`, or null when the reader has read
    /// none. Valid as long as the history.
    pub fn zoneName(reader: *const Reader, name: u64) ?[]const u8 {
        const entry = reader.zone_names.get(name) orelse return null;
        return entry.name();
    }

    /// The scope a zone's name was registered in: its system.
    pub fn zoneScope(reader: *const Reader, name: u64) ?u32 {
        const entry = reader.zone_names.get(name) orelse return null;
        return entry.scope;
    }

    /// Reads the names, records and messages written since the last update, and forgets the
    /// frames and messages the history has overwritten. Records overwritten before they
    /// could be read are skipped. Fails only with `error.OutOfMemory`.
    pub fn update(reader: *Reader) !void {
        try reader.readNames();
        const written = reader.history.writtenCount();
        const oldest = written -| reader.history.capacity();
        if (reader.indexed < oldest) reader.indexed = oldest;
        const chunk = 4096;
        try reader.scratch.resize(reader.allocator, chunk);
        while (reader.indexed < written) {
            const end = @min(written, reader.indexed + chunk);
            const sound_from = reader.history.copy(reader.indexed, end, reader.scratch.items);
            const copied = reader.scratch.items[0 .. end - reader.indexed];
            for (copied[sound_from - reader.indexed ..], sound_from..) |record, number| try reader.indexRecord(record, number);
            reader.indexed = end;
        }
        reader.evict();
        try reader.indexMessages();
    }

    /// Indexes the messages written since the last update, and forgets those overwritten.
    fn indexMessages(reader: *Reader) !void {
        const history = reader.history;
        const written = history.messagesWrittenCount();
        const oldest = written -| history.messages.len;
        if (reader.messages_indexed < oldest) reader.messages_indexed = oldest;
        while (reader.messages_indexed < written) : (reader.messages_indexed += 1) {
            var message: Message = undefined;
            if (!history.copyMessage(reader.messages_indexed, &message)) continue;
            try reader.messages.append(reader.allocator, .{ .number = reader.messages_indexed, .begin_ns = message.begin_ns, .lane = message.lane, .level = message.level });
        }
        reader.evictMessages();
    }

    fn evictMessages(reader: *Reader) void {
        const oldest = reader.history.messagesWrittenCount() -| reader.history.messages.len;
        var gone: usize = 0;
        for (reader.messages.items) |indexed| {
            if (indexed.number >= oldest) break;
            gone += 1;
        }
        if (gone == 0) return;
        const kept = reader.messages.items.len - gone;
        std.mem.copyForwards(IndexedMessage, reader.messages.items[0..kept], reader.messages.items[gone..]);
        reader.messages.shrinkRetainingCapacity(kept);
    }

    /// Calls `visit` with each indexed message logged from `begin_ns` up to, not including,
    /// `end_ns` that the history still holds, in the order they were written. The message
    /// passed is a copy that lives only for the call. Returns false when some had been
    /// overwritten; fails with what `visit` fails with.
    pub fn messagesIn(reader: *Reader, begin_ns: u64, end_ns: u64, context: anytype, comptime visit: fn (@TypeOf(context), *const Message) anyerror!void) !bool {
        var complete = true;
        for (reader.messages.items) |indexed| {
            if (indexed.begin_ns < begin_ns or indexed.begin_ns >= end_ns) continue;
            var message: Message = undefined;
            if (!reader.history.copyMessage(indexed.number, &message)) {
                complete = false;
                continue;
            }
            try visit(context, &message);
        }
        return complete;
    }

    /// Writes to `out[i]` the most severe level among the messages of `frames[i]`: 0 where
    /// the frame has none, else the `log.Level` integer plus one. `frames` must be in time
    /// order, as `finishedFrames` gives them, and `out` at least as long.
    pub fn frameMessageLevels(reader: *const Reader, frames: []const Frame, out: []u8) void {
        @memset(out, 0);
        if (frames.len == 0) return;
        for (reader.messages.items) |indexed| {
            if (indexed.begin_ns < frames[0].begin_ns) continue;
            // The last frame that begins at or before the message.
            var low: usize = 0;
            var high: usize = frames.len;
            while (low < high) {
                const middle = low + (high - low) / 2;
                if (frames[middle].begin_ns <= indexed.begin_ns) low = middle + 1 else high = middle;
            }
            const position = low - 1;
            const frame = frames[position];
            if (frame.end_ns != 0 and indexed.begin_ns >= frame.end_ns) continue;
            out[position] = @max(out[position], indexed.level + 1);
        }
    }

    fn readNames(reader: *Reader) !void {
        const names = reader.history.publishedNames();
        for (names[reader.names_read..]) |*entry| {
            switch (entry.kind) {
                .lane => {
                    const lane: usize = @intCast(entry.key);
                    while (reader.lane_names.items.len <= lane) try reader.lane_names.append(reader.allocator, "thread");
                    reader.lane_names.items[lane] = entry.name();
                },
                .scope => try reader.scope_names.put(reader.allocator, @intCast(entry.key), entry.name()),
                .zone => try reader.zone_names.put(reader.allocator, entry.key, entry),
            }
        }
        reader.names_read = @intCast(names.len);
    }

    fn indexRecord(reader: *Reader, record: Record, number: u64) !void {
        if (record.event == .frame) return reader.indexFrame(record, number);
        const frames = reader.frames.items;
        if (frames.len == 0 or record.begin_ns < frames[0].begin_ns) return;
        // Usually the latest frame, or one just before it.
        var position = frames.len;
        while (position > 0) {
            position -= 1;
            if (record.begin_ns >= frames[position].begin_ns) break;
        }
        const frame = &frames[position];
        frame.first_number = @min(frame.first_number, number);
        frame.end_number = @max(frame.end_number, number + 1);
        if (position + 1 == frames.len and frame.end_ns == 0) {
            try reader.latest.append(reader.allocator, .{ .number = number, .begin_ns = record.begin_ns });
        }
    }

    fn indexFrame(reader: *Reader, mark: Record, number: u64) !void {
        var frame: Frame = .{ .index = mark.name, .begin_ns = mark.begin_ns, .first_number = number, .end_number = number + 1 };
        if (reader.frames.items.len > 0) {
            const previous = &reader.frames.items[reader.frames.items.len - 1];
            if (previous.end_ns == 0) previous.end_ns = mark.begin_ns;
        }
        // Records indexed into the previous frame that begin at or after this mark are this
        // frame's: another lane's zones can reach the writer before the mark does.
        for (reader.latest.items) |seen| {
            if (seen.begin_ns < mark.begin_ns) continue;
            frame.first_number = @min(frame.first_number, seen.number);
            frame.end_number = @max(frame.end_number, seen.number + 1);
        }
        reader.latest.clearRetainingCapacity();
        try reader.frames.append(reader.allocator, frame);
    }

    /// Frames whose first record has been overwritten leave whole.
    fn evict(reader: *Reader) void {
        const oldest = reader.history.writtenCount() -| reader.history.capacity();
        var gone: usize = 0;
        for (reader.frames.items) |frame| {
            if (frame.first_number >= oldest) break;
            gone += 1;
        }
        if (gone == 0) return;
        const kept = reader.frames.items.len - gone;
        std.mem.copyForwards(Frame, reader.frames.items[0..kept], reader.frames.items[gone..]);
        reader.frames.shrinkRetainingCapacity(kept);
    }

    /// Calls `visit` with each zone that begins from `begin_ns` up to, not including,
    /// `end_ns`, among the records `frames` cover, on every lane, in the order the writer
    /// wrote them: a zone is written when it ends, so inner zones come before the zone that
    /// holds them. Returns false when some of the records have been overwritten since they
    /// were indexed; fails with `error.OutOfMemory` or what `visit` fails with.
    pub fn zonesIn(reader: *Reader, frames: []const Frame, begin_ns: u64, end_ns: u64, context: anytype, comptime visit: fn (@TypeOf(context), Record) anyerror!void) !bool {
        var first_number: u64 = std.math.maxInt(u64);
        var end_number: u64 = 0;
        for (frames) |frame| {
            first_number = @min(first_number, frame.first_number);
            end_number = @max(end_number, frame.end_number);
        }
        const chunk = 4096;
        try reader.scratch.resize(reader.allocator, chunk);
        var complete = true;
        var number = first_number;
        while (number < end_number) {
            const end = @min(end_number, number + chunk);
            const sound_from = reader.history.copy(number, end, reader.scratch.items);
            if (sound_from > number) complete = false;
            const copied = reader.scratch.items[0 .. end - number];
            for (copied[sound_from - number ..]) |record| {
                if (record.event != .zone) continue;
                if (record.begin_ns < begin_ns or record.begin_ns >= end_ns) continue;
                try visit(context, record);
            }
            number = end;
        }
        return complete;
    }
};

// ---- tests ---------------------------------------------------------------------------

const testing = std.testing;

fn zoneRecord(name: u64, begin_ns: u64, duration_ns: u32, depth: u16, lane: u16) Record {
    return .{ .name = name, .begin_ns = begin_ns, .duration_ns = duration_ns, .scope = 1, .depth = depth, .lane = lane, .event = .zone };
}

fn frameRecord(index: u64, begin_ns: u64) Record {
    return .{ .name = index, .begin_ns = begin_ns, .duration_ns = 0, .scope = 0, .depth = 0, .lane = 0, .event = .frame };
}

test "a reader indexes frames and claims a lane's zones that reach the writer before the mark" {
    var history = try History.init(testing.allocator, 64 * @sizeOf(Record), 8, 4);
    defer history.deinit(testing.allocator);
    var reader = Reader.init(&history, testing.allocator);
    defer reader.deinit();
    history.append(frameRecord(1, 100));
    history.append(zoneRecord(7, 110, 10, 0, 0));
    // The render lane's zone in frame 2 is drained before the main lane's mark for frame 2.
    history.append(zoneRecord(8, 205, 5, 0, 1));
    history.append(frameRecord(2, 200));
    history.append(zoneRecord(7, 210, 10, 0, 0));
    history.append(frameRecord(3, 300));
    try reader.update();
    const frames = reader.finishedFrames();
    try testing.expectEqual(@as(usize, 2), frames.len);
    try testing.expectEqual(@as(u64, 200), frames[0].end_ns);

    const Collect = struct {
        names: std.ArrayList(u64) = .empty,
        fn visit(collect: *@This(), record: Record) !void {
            try collect.names.append(testing.allocator, record.name);
        }
    };
    var collected: Collect = .{};
    defer collected.names.deinit(testing.allocator);
    const frame = frames[1];
    try testing.expect(try reader.zonesIn(frames[1..2], frame.begin_ns, frame.end_ns, &collected, Collect.visit));
    std.mem.sort(u64, collected.names.items, {}, std.sort.asc(u64));
    try testing.expectEqualSlices(u64, &.{ 7, 8 }, collected.names.items);
}

test "frames whose first record is overwritten leave whole" {
    var history = try History.init(testing.allocator, 8 * @sizeOf(Record), 8, 4);
    defer history.deinit(testing.allocator);
    var reader = Reader.init(&history, testing.allocator);
    defer reader.deinit();
    for (0..5) |frame| {
        const begin: u64 = 100 * (frame + 1);
        history.append(frameRecord(frame, begin));
        history.append(zoneRecord(7, begin + 10, 10, 0, 0));
        try reader.update();
    }
    history.append(frameRecord(5, 600));
    try reader.update();
    // Eleven records through a history of eight: frames 0 and 1 began at records 0 and 2.
    var kept: [8]u64 = undefined;
    var count: usize = 0;
    for (reader.finishedFrames()) |frame| {
        kept[count] = frame.index;
        count += 1;
    }
    try testing.expectEqualSlices(u64, &.{ 2, 3, 4 }, kept[0..count]);
}

test "a copy keeps only records the writer cannot have overwritten" {
    var history = try History.init(testing.allocator, 4 * @sizeOf(Record), 8, 4);
    defer history.deinit(testing.allocator);
    for (0..6) |number| history.append(zoneRecord(number, number, 1, 0, 0));
    var out: [6]Record = undefined;
    const sound_from = history.copy(0, 6, &out);
    try testing.expectEqual(@as(u64, 2), sound_from);
    try testing.expectEqual(@as(u64, 5), out[5].name);
}

test "a reader finds messages by time, and frames by their most severe message" {
    var history = try History.init(testing.allocator, 64 * @sizeOf(Record), 8, 4);
    defer history.deinit(testing.allocator);
    var reader = Reader.init(&history, testing.allocator);
    defer reader.deinit();
    history.append(frameRecord(1, 100));
    history.appendMessage(.init(150, 2, 0, 2, "info in frame 1"));
    history.append(frameRecord(2, 200));
    history.appendMessage(.init(210, 2, 1, 3, "warn in frame 2"));
    history.appendMessage(.init(220, 2, 0, 1, "debug in frame 2"));
    history.append(frameRecord(3, 300));
    try reader.update();
    const Collect = struct {
        texts: std.ArrayList([]const u8) = .empty,
        fn visit(collect: *@This(), message: *const Message) !void {
            try collect.texts.append(testing.allocator, try testing.allocator.dupe(u8, message.text()));
        }
    };
    var collected: Collect = .{};
    defer {
        for (collected.texts.items) |text| testing.allocator.free(text);
        collected.texts.deinit(testing.allocator);
    }
    try testing.expect(try reader.messagesIn(200, 300, &collected, Collect.visit));
    try testing.expectEqual(@as(usize, 2), collected.texts.items.len);
    try testing.expectEqualStrings("warn in frame 2", collected.texts.items[0]);
    var levels: [2]u8 = undefined;
    reader.frameMessageLevels(reader.finishedFrames(), &levels);
    try testing.expectEqualSlices(u8, &.{ 3, 4 }, &levels);

    // Three more through a ring of four: the first two are gone.
    for (0..3) |index| history.appendMessage(.init(310 + index, 2, 0, 2, "later"));
    try reader.update();
    try testing.expectEqual(@as(usize, 4), reader.messages.items.len);
    try testing.expectEqual(@as(u64, 220), reader.messages.items[0].begin_ns);
}

test "a message longer than a message keeps is cut short" {
    const long: [300]u8 = @splat('x');
    const message: Message = .init(1, 0, 0, 2, &long);
    try testing.expectEqual(@as(usize, max_message_bytes), message.text().len);
}

test "names reach a reader once published" {
    var history = try History.init(testing.allocator, 4 * @sizeOf(Record), 8, 4);
    defer history.deinit(testing.allocator);
    var reader = Reader.init(&history, testing.allocator);
    defer reader.deinit();
    history.addName(.lane, 1, 0, "render");
    history.addName(.scope, 3, 0, "figure_runtime");
    history.addName(.zone, 99, 3, "fig.cmd.apply");
    try reader.update();
    try testing.expectEqualStrings("render", reader.laneName(1));
    try testing.expectEqualStrings("thread", reader.laneName(0));
    try testing.expectEqualStrings("figure_runtime", reader.scopeName(3).?);
    try testing.expectEqualStrings("fig.cmd.apply", reader.zoneName(99).?);
    try testing.expectEqual(@as(?u32, 3), reader.zoneScope(99));
}
