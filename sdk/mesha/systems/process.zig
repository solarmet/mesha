//! The process system: other programs, run for whoever asks, without the frame waiting on
//! them. It draws nothing.
//!
//! - `commands.process` takes the requests, applied in order right after each dispatch:
//!   `spawn` answers the asker's inbox with the program's handle.
//! - `process` is the system's own state, one row; `process_children` lists the programs
//!   and the table each keeps its state in.
//! - Each program has a table of its own, one row: whether it runs, how it ended, and for its
//!   output and its errors how much is kept and where to read it.
//! - `events.process` tells what happened: output arrived, a program ended.
//!
//! The runtime (`runtime/process.zig`) reads and writes the programs' streams away from the
//! frame; once a frame, before the dispatch, it moves what was read to where readers see it
//! and tells of it. A frame never waits on a program.
//!
//! A stream's output is kept until its readers `consume` it. Bytes are counted from the
//! stream's start: a reader keeps the offset it has read to, and the table says the offset
//! of the first byte kept, so a reader that reads again before its `consume` lands reads
//! nothing twice. The kept bytes are read through the program's `Output`, whose address is in
//! its table: valid until the system next applies commands or delivers.

const std = @import("std");
const Atom = @import("../core/atom.zig").Atom;
const memory_mod = @import("../core/memory.zig");
const Table = @import("../core/table.zig");
const sequencer = @import("../core/sequencer.zig");

/// How many programs can be known at once, running or ended and not yet released.
pub const max_processes = 32;

/// The most arguments one `spawn` passes, the program's name among them: a longer `argv`
/// answers `bad_arguments`. The platform's own limit on a command line's length may refuse a
/// shorter one (on Windows, 32,767 characters), which the asker keeps below.
pub const max_arguments = 16384;

/// A program's handle; `none` is no program.
pub const Process = enum(u32) { none = 0, _ };

/// A program's output stream.
pub const Stream = enum(u8) { stdout, stderr };

/// What a program's stream is connected to.
pub const Pipe = enum(u8) {
    /// To this system: input is sent with `write`, output read through the program's table.
    pipe,
    /// To nothing.
    ignore,
};

/// Separates the arguments in `spawn`'s `argv`, which a command row holds as one text.
pub const argument_separator = '\x1f';

/// A request to the process system, a row of `commands.process`.
pub const CmdPayload = union(enum) {
    /// Runs a program and answers `reply` with a `SpawnedMsg`. `argv` is the program and its
    /// arguments, separated by `argument_separator`; the program is looked for on `PATH`
    /// unless it is a path. `cwd` empty runs it where the engine runs. The program starts with
    /// the engine's environment and the variables `environment` gives. A request with no
    /// reply inbox runs the program unwatched: it is released when it ends.
    spawn: struct {
        /// The program and its arguments, separated by `argument_separator`.
        argv: []const u8,
        /// The directory the program runs in; empty for the engine's.
        cwd: []const u8,
        /// Variables the program is given besides the engine's: `NAME=value` pairs separated
        /// by `argument_separator`, each split at its first `=`, so a value may hold `=` or be
        /// empty. A pair replaces a variable of the same name the engine has (on Windows,
        /// where names ignore case, of any case), and a later pair an earlier one. A pair with
        /// no `=`, an empty name or a NUL, or on Windows one that is not WTF-8, makes the spawn
        /// answer `bad_arguments`. The engine's environment is the one it has now, or the one
        /// it started with where the engine cannot read its live environment, as on Windows.
        /// Empty gives nothing more. Copied into the request's row, as `argv` is.
        environment: []const u8 = "",
        /// What the program's input is connected to.
        stdin: Pipe,
        /// What the program's output is connected to.
        stdout: Pipe,
        /// What the program's errors are connected to.
        stderr: Pipe,
        /// Where the `SpawnedMsg` goes. With no inbox the program runs unwatched.
        reply: sequencer.ReplyTo,
    },
    /// Sends `bytes` to the program's input, after what was sent before.
    write: struct { process: Process, bytes: []const u8 },
    /// Closes the program's input once what was sent is written.
    close_input: Process,
    /// Forgets a stream's output before offset `through`, counted from the stream's start.
    consume: struct { process: Process, stream: Stream, through: u64 },
    /// Ends the program. `exited` follows.
    kill: Process,
    /// Forgets the program and its table, ending it first if it runs.
    release: Process,
};

/// What became of a `spawn`.
pub const SpawnResult = enum(u8) {
    /// The program runs.
    spawned,
    /// No such program.
    not_found,
    /// The program may not be run.
    access_denied,
    /// `argv` names no program or more than `max_arguments`, or `environment` holds a pair it
    /// cannot give.
    bad_arguments,
    /// `max_processes` programs are known.
    too_many_processes,
    /// Memory ran out.
    out_of_memory,
    /// The program could not be started for another reason.
    failed,
};

/// The answer to `spawn`. `process` is `none` unless `result` is `spawned`.
pub const SpawnedMsg = struct { process: Process, result: SpawnResult };

/// `commands.process`, the requests the process system applies right after each dispatch.
pub const commands_table_name = "commands.process";
/// The typed handle on `commands.process`.
pub const Requests = sequencer.Commands(CmdPayload);

/// Asks the process system for `wanted`: a row of `commands.process`, whose slices are copied
/// into the row.
pub fn request(memory: *memory_mod.Memory, tables: *Table.Registry, wanted: CmdPayload) void {
    Requests.of(memory, tables, commands_table_name).push(wanted);
}

/// `events.process`: output arrived, a program ended. Any system reads it with a cursor of its
/// own.
pub const events_table_name = "events.process";
/// The typed handle on `events.process`.
pub const Events = sequencer.Events(Event);

/// What happened to a program.
pub const Event = union(enum) {
    /// More of the stream's output is kept.
    output: struct { process: Process, stream: Stream },
    /// The program ended, and all its output is kept. `code` is its exit code, or the
    /// negated signal that ended it, or -1 when how it ended is not known.
    exited: struct { process: Process, code: i32 },
};

/// `process`, the system's own state: one row.
pub const state_table_name = "process";
/// A view of the one row of `process`.
pub const StateRow = struct {
    /// Programs known: running, or ended and not yet released.
    known: *u32,
    /// Programs that run.
    running: *u32,
};

/// `process_children`, a row per program known: its handle and the name of its table.
pub const children_table_name = "process_children";
/// A view of a row of `process_children`.
pub const ChildEntry = struct {
    /// The program's handle, a `Process`.
    process: *u32,
    /// The name of the table the program keeps its state in.
    table: *Atom,
};

/// Whether a program runs or has ended.
pub const State = enum(u8) { running, exited };

/// The one row of a program's own table.
pub const ChildRow = struct {
    /// The program's handle, a `Process`.
    process: *u32,
    /// A `State`.
    state: *u8,
    /// As `Event.exited` tells it; 0 while the program runs.
    exit_code: *i32,
    /// A `*const Output`; see the file comment for how long it may be read.
    output_address: *u64,
    /// The offset, from the stream's start, of the first byte kept of the program's output.
    stdout_offset: *u64,
    /// How many bytes of the program's output are kept.
    stdout_bytes: *u64,
    /// The offset, from the stream's start, of the first byte kept of the program's errors.
    stderr_offset: *u64,
    /// How many bytes of the program's errors are kept.
    stderr_bytes: *u64,
};

/// A program's kept output, read through the address in its table.
pub const Output = struct {
    /// What is kept of each stream, by the `Stream`'s number.
    streams: [2]Kept,

    /// The bytes kept of one stream.
    pub const Kept = struct {
        /// The bytes, oldest first. The process system's; a reader only reads them.
        bytes: std.ArrayList(u8) = .empty,
        /// The offset of `bytes[0]` from the stream's start.
        offset: u64 = 0,
    };

    /// The kept bytes of `stream` from offset `from`: none when all before it was consumed
    /// and nothing after it arrived.
    pub fn after(output: *const Output, stream: Stream, from: u64) []const u8 {
        const kept = &output.streams[@intFromEnum(stream)];
        const start = @max(from, kept.offset) - kept.offset;
        if (start >= kept.bytes.items.len) return &.{};
        return kept.bytes.items[start..];
    }

    /// The offset just past the last byte kept of `stream`.
    pub fn end(output: *const Output, stream: Stream) u64 {
        const kept = &output.streams[@intFromEnum(stream)];
        return kept.offset + kept.bytes.items.len;
    }
};

/// The name the schema of a program's table is registered under: the fields of `ChildRow`.
pub const child_schema_name = "process_child";

/// The names of the programs' tables, by slot: `process_00` to `process_31`.
pub const child_table_names: [max_processes][]const u8 = blk: {
    var names: [max_processes][]const u8 = undefined;
    for (&names, 0..) |*name, slot| name.* = std.fmt.comptimePrint("process_{d:0>2}", .{slot});
    break :blk names;
};

/// A program's table and its memory scope share a name: one of these, by its slot.
pub const child_table_atoms: [max_processes]Atom = blk: {
    var atoms: [max_processes]Atom = undefined;
    for (&atoms, child_table_names) |*atom, name| atom.* = Atom.from(name);
    break :blk atoms;
};

/// Makes `events.process`, `process` and `process_children` unless they are there, and registers
/// the schema of a program's table. `scratch` allocates the schemas for the call.
pub fn ensureTables(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    try Events.ensure(scratch, atoms, tables, events_table_name);
    try atoms.tryInternAll(&.{ state_table_name, children_table_name, child_schema_name });
    try atoms.tryInternAll(&child_table_names);

    var state: Table.Schema = undefined;
    try state.init(scratch.allocator, atoms, 2);
    defer state.deinit();
    try state.addFieldFallible("known", u32, .int);
    try state.addFieldFallible("running", u32, .int);
    _ = try tables.ensureSingleton(&state, Atom.from(state_table_name), .{ .known = @as(u32, 0), .running = @as(u32, 0) }, .durable);

    var entries: Table.Schema = undefined;
    try entries.init(scratch.allocator, atoms, 2);
    defer entries.deinit();
    try entries.addFieldFallible("process", u32, .int);
    try entries.addFieldFallible("table", Atom, .atom);
    _ = try tables.ensure(&entries, max_processes, Atom.from(children_table_name), .durable);

    if (tables.schemas.get(Atom.from(child_schema_name)) != null) return;
    var child: Table.Schema = undefined;
    try child.init(scratch.allocator, atoms, 8);
    defer child.deinit();
    try child.addFieldFallible("process", u32, .int);
    try child.addFieldFallible("state", u8, .int);
    try child.addFieldFallible("exit_code", i32, .int);
    try child.addFieldFallible("output_address", u64, .int);
    try child.addFieldFallible("stdout_offset", u64, .int);
    try child.addFieldFallible("stdout_bytes", u64, .int);
    try child.addFieldFallible("stderr_offset", u64, .int);
    try child.addFieldFallible("stderr_bytes", u64, .int);
    try tables.registerSchema(Atom.from(child_schema_name), &child);
}

/// The one row of `process`; null before `ensureTables`.
pub fn stateRow(tables: *Table.Registry) ?StateRow {
    const found = tables.findByName(Atom.from(state_table_name)) orelse return null;
    return found.getRow(.{ .row = 0, .generation = found.rowGeneration(0) }, StateRow);
}

/// The table `process` keeps its state in; null for a program not known.
pub fn tableOf(tables: *Table.Registry, process: Process) ?*Table {
    const entries = tables.findByName(Atom.from(children_table_name)) orelse return null;
    var rows = entries.readQuery(ChildEntry);
    while (rows.next()) |row| {
        if (row.view.process.* == @intFromEnum(process)) return tables.findByName(row.view.table.*);
    }
    return null;
}

/// The row of `process`'s own table; null for a program not known.
pub fn rowOf(tables: *Table.Registry, process: Process) ?Table.ReadView(ChildRow) {
    const found = tableOf(tables, process) orelse return null;
    var rows = found.readQuery(ChildRow);
    const row = rows.next() orelse return null;
    return row.view;
}

/// `process`'s kept output, to read until the system next applies commands or delivers.
pub fn outputOf(tables: *Table.Registry, process: Process) ?*const Output {
    const row = rowOf(tables, process) orelse return null;
    if (row.output_address.* == 0) return null;
    return @ptrFromInt(row.output_address.*);
}

/// What a reader of `process` declares: the list of programs and the program's own table.
pub fn declareProcess(access: *sequencer.Access, tables: *Table.Registry, process: Process) void {
    const entries_name = Atom.from(children_table_name);
    const entries = tables.findByName(entries_name) orelse return;
    access.read(entries_name);
    var rows = entries.readQuery(ChildEntry);
    while (rows.next()) |row| {
        if (row.view.process.* == @intFromEnum(process)) access.read(row.view.table.*);
    }
}
