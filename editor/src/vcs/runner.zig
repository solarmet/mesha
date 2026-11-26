//! The runner the editor's version-control panels run their programs through, git's and
//! Perforce's: the one place an editor system runs a program, waits for it to end without the
//! frame waiting, and hears how it ended. It draws nothing.
//!
//! - An owner queues a `Job` (`run`): a program and its arguments, what is written to its
//!   input, the variables it is given and where it runs. The runner starts at most
//!   `max_running` programs at once, across every owner, in the order they were queued; an
//!   owner's job marked `alone` runs with no other job of that owner's.
//! - Once the program has ended, the runner answers the owner with a `Finished`, and keeps the
//!   job until the owner has read what the program said (`output`) and lets it go (`release`).
//! - `editor_vcs_log` keeps the last `max_logged` jobs that finished, as a person reads them:
//!   the command line, where it ran, how it ended and the first `max_logged_bytes` of what it
//!   said and of its errors.
//! - While a program runs the runner hears the clock each frame and turns `phase` once each
//!   `phase_step_seconds`, which an owner draws as a spinner (`spinner`) beside the command
//!   that runs (`running`). While none runs it hears nothing, and the host may sleep. `phase`
//!   is the runner's own state, so its turning redraws no panel: an owner's panel turns its
//!   spinner by reading `phase` in a kernel of its own each frame it is `busy` (see `phase`).
//! - An answer may reach its owner after the job is gone, given up or released past
//!   `max_unreleased` meanwhile: `output` then gives null, and the owner drops the answer.
//!
//! Each job is one process, run directly and never through a shell, so it starts as it does
//! everywhere on Windows, where a process costs the most: an owner batches its work into few
//! jobs. A program counts as ended once its exit code is known and its output's pipes are
//! closed, so on Windows one whose own children (a credential helper, ssh) hold its pipes ends
//! only once they let them go, and ending it does not end them: its owner gives the job up
//! (`giveUp`), and its later jobs run.
//!
//! Everything the runner keeps is in its tables, and nothing it holds across frames is a
//! pointer, so its jobs survive a reload of the editor. The jobs are known by a serial, which
//! the runner counts in its own row and never gives twice while the host runs.

const std = @import("std");
const builtin = @import("builtin");
const mesha = @import("mesha");
const Atom = mesha.Atom;
const Table = mesha.Table;
const memory_mod = mesha.memory;
const plugin = mesha.plugin;
const process = mesha.process;
const sequencer = mesha.sequencer;
const time = mesha.time;
const open = @import("../open.zig");

const Log = mesha.log.scope("vcs_runner");

/// The most programs the runner runs at once, across every owner.
pub const max_running = 4;
/// The most finished jobs the runner keeps for their owners to read: past it, the oldest is
/// released unread, with a warning naming its owner.
pub const max_unreleased = 16;
/// The most jobs `editor_vcs_log` keeps: the latest to finish.
pub const max_logged = 64;
/// The most of what a program said, and of its errors, that `editor_vcs_log` keeps: the first.
pub const max_logged_bytes = 64 * 1024;
/// How long the spinner shows each of its frames, in seconds.
pub const phase_step_seconds: f32 = 0.1;

// ---- what an owner asks ------------------------------------------------------------------------

/// Whether a job may run beside its owner's others.
pub const Order = enum(u8) {
    /// It runs beside any other job.
    shared,
    /// Nothing else of its owner runs with it: it starts once none of its owner's jobs runs,
    /// and while it waits or runs no later job of its owner starts.
    alone,
};

/// A program to run. Its slices are copied as the job is queued.
pub const Job = struct {
    /// Answered with a `Finished` once the program has ended. Its inbox (`sequencer.inboxOf`
    /// the owner's system) names the job's owner, as `busy`, `running`, `giveUp` and
    /// `declareJobs` take it; its user data comes back with the answer.
    owner: sequencer.ReplyTo,
    /// The program and its arguments, separated by `process.argument_separator`. The program is
    /// looked for on `PATH` unless it is a path.
    argv: []const u8,
    /// Written to the program's input, which is then closed. Empty: the program's input is
    /// connected to nothing, so a program that reads it reads its end at once.
    input: []const u8 = "",
    /// Variables the program is given besides the engine's, as `process.CmdPayload.spawn`'s
    /// `environment` gives them.
    environment: []const u8 = "",
    /// Where the program runs. Empty: the working directory as the runner takes the job, its
    /// path from `os_places`, absolute. The runner takes a job the frame after it is queued, so
    /// a project switched to in between would have it run in the new project: a panel passes
    /// its repository's root, which it knows, rather than empty.
    directory: []const u8 = "",
    /// Whether the job may run beside its owner's others.
    order: Order = .shared,
    /// The command line as a person reads it, in the log and beside the spinner. Empty: `argv`,
    /// a space between its arguments.
    shown: []const u8 = "",
};

/// What a job came to: the whole payload of the answer to its owner. It travels between the
/// editor's own systems, which one image builds, so it is no part of what the host and a plugin
/// share (`plugin.boundary_roots`). The owner reads the job's `output` and then `release`s it;
/// when `output` gives null the job is gone (given up, or released past `max_unreleased`) and
/// the owner drops the answer, which reports nothing it still wants. Every `Finished` is
/// followed by a `release` of its job, whether or not the program ran.
pub const Finished = extern struct {
    /// The job's serial: what `output` and `release` take.
    job: u32,
    /// The program's exit code, or the negated signal that ended it, or -1 when how it ended is
    /// not known or it never ran.
    code: i32,
    /// A `process.SpawnResult`. When it is not `spawned` the program never ran: `code` is -1,
    /// `output` gives an empty `Output`, and the owner releases the job as any other.
    started: u8,
    /// Zero, so the answer's bytes are all set.
    reserved: [3]u8 = @splat(0),
};

/// A request to the runner: a row of `commands.editor_vcs_runner`.
pub const Request = union(enum) {
    /// Queues a job.
    run: Job,
    /// The owner is done with the job of this serial: its program is let go, ended first if it
    /// still runs, and no answer follows for a job that has not finished.
    release: u32,
    /// Every job of the owner whose inbox this is, queued, running or finished, is let go, as
    /// `release` lets one go: no answer follows for any of them.
    give_up: Atom,
};

/// The runner's requests, `Request`s, which it takes in its run.
pub const requests_table_name = "commands.editor_vcs_runner";
/// The typed handle on `commands.editor_vcs_runner`.
pub const Requests = sequencer.Commands(Request);

/// Queues `job`: the runner takes it in its next run, the next frame's for an owner that runs
/// after it, and answers `job.owner` once its program has ended. The caller's system declares
/// `commands.editor_vcs_runner` written.
pub fn run(memory: *memory_mod.Memory, tables: *Table.Registry, job: Job) void {
    Requests.of(memory, tables, requests_table_name).push(.{ .run = job });
}

/// Lets the job `job` go once its owner has read what its program said (`output`): its program
/// and what it kept go with it. Every `Finished` is followed by a `release` of its job, whether
/// or not the program ran. A job not finished yet is given up: its program is ended and
/// no answer follows. A job the runner no longer has is left alone. The caller's system
/// declares `commands.editor_vcs_runner` written.
pub fn release(memory: *memory_mod.Memory, tables: *Table.Registry, job: u32) void {
    Requests.of(memory, tables, requests_table_name).push(.{ .release = job });
}

/// Gives up every job of `owner` (its inbox): those queued are dropped, those running are
/// released, which ends their programs, and those finished are released; no `Finished`
/// follows for any of them, and the owner's jobs queued after this run. As `C-g` does in a
/// panel. An answer the runner gave before it took this may still reach the owner, the frame
/// after: the runner takes the give-up first, before its owners run, so such an answer finds
/// its job gone (`output` gives null) and the owner drops it, with no count of its own. The
/// caller's system declares `commands.editor_vcs_runner` written.
pub fn giveUp(memory: *memory_mod.Memory, tables: *Table.Registry, owner: Atom) void {
    Requests.of(memory, tables, requests_table_name).push(.{ .give_up = owner });
}

// ---- what an owner reads -----------------------------------------------------------------------

/// What a job's program said, read in place, from the process system's own storage: good for
/// the frame it was read in, as the runner may release the job in its next run. Once the job has
/// finished nothing more arrives. A kernel copies what it keeps.
pub const Output = struct {
    /// What it wrote to its output.
    said: []const u8,
    /// What it wrote to its errors.
    errors: []const u8,
};

/// What the job `job`'s program has said so far: empty for a job that never ran or has not
/// started yet; null when the runner no longer holds the job, given up or released, and an
/// answer for it is to be dropped. A kernel's system declares its jobs with `declareJobs`.
pub fn output(tables: *Table.Registry, job: u32) ?Output {
    const nothing: Output = .{ .said = "", .errors = "" };
    const jobs = tables.findByName(jobs_table) orelse return null;
    var rows = jobs.readQuery(struct { serial: *u32, process: *u32 });
    while (rows.next()) |row| {
        if (row.view.serial.* != job) continue;
        const program: process.Process = @enumFromInt(row.view.process.*);
        if (program == .none) return nothing;
        const kept = process.outputOf(tables, program) orelse return nothing;
        return .{ .said = kept.after(.stdout, 0), .errors = kept.after(.stderr, 0) };
    }
    return null;
}

/// Whether a job's program ran and ended well: started, exit code 0, and its answer still held
/// by the runner as it was read (`said`, what `output` gave: null when the job was let go), so
/// that what it said can be read.
pub fn ranWell(finished: Finished, said: ?Output) bool {
    const ran = finished.started == @intFromEnum(process.SpawnResult.spawned);
    return said != null and ran and finished.code == 0;
}

/// What an owner's system declares so that its kernels may read its jobs (`busy`, `running`,
/// `output`) and the spinner (`phase`): the runner's jobs, its own row, and the table of each
/// program of `owner`'s jobs.
pub fn declareJobs(owner_access: *sequencer.Access, tables: *Table.Registry, owner: Atom) void {
    const jobs = tables.findByName(jobs_table) orelse return;
    owner_access.read(jobs_table);
    // Where the spinner has turned (`phase`), which an owner copies while it is busy.
    if (tables.findByName(state_table) != null) owner_access.read(state_table);
    var rows = jobs.readQuery(struct { owner: *Atom, process: *u32 });
    while (rows.next()) |row| {
        if (row.view.owner.* != owner or row.view.process.* == 0) continue;
        process.declareProcess(owner_access, tables, @enumFromInt(row.view.process.*));
    }
}

/// Whether a job of `owner` (its inbox) is queued or runs.
pub fn busy(tables: *Table.Registry, owner: Atom) bool {
    const jobs = tables.findByName(jobs_table) orelse return false;
    var rows = jobs.readQuery(struct { owner: *Atom, state: *u8 });
    while (rows.next()) |row| {
        if (row.view.owner.* == owner and row.view.state.* != @intFromEnum(JobState.finished)) return true;
    }
    return false;
}

/// The command line, as a person reads it, of the job of `owner` (its inbox) that runs, the
/// oldest when several do: what the owner shows beside its spinner. Empty when none runs. The
/// text is the table's: good for the frame it was read in, as a freed row's text is shed
/// between frames.
pub fn running(tables: *Table.Registry, owner: Atom) []const u8 {
    const jobs = tables.findByName(jobs_table) orelse return "";
    var rows = jobs.readQuery(struct { serial: *u32, owner: *Atom, state: *u8, shown: []const u8 });
    var oldest: ?u32 = null;
    var shown: []const u8 = "";
    while (rows.next()) |row| {
        if (row.view.owner.* != owner or !runs(row.view.state.*)) continue;
        if (oldest) |serial| if (serial < row.view.serial.*) continue;
        oldest = row.view.serial.*;
        shown = row.view.shown;
    }
    return shown;
}

/// How far the spinner has turned: one step each `phase_step_seconds` while a program runs.
/// A kernel reads it under `declareJobs`, which declares the runner's row. It is the runner's
/// own state, and its change redraws no panel: an owner whose panel shows a
/// spinner reads `phase` in a kernel of its own each frame `busy` is true for it, keeps it in
/// its own table (which redraws its panels when it changes), and draws `spinner` of the value
/// kept. Its system stays active while `busy` is true; the clock's frames the runner hears
/// meanwhile keep the host making frames for it.
pub fn phase(tables: *Table.Registry) u32 {
    const found = tables.findByName(state_table) orelse return 0;
    var rows = found.readQuery(struct { phase: *u32 });
    const row = rows.next() orelse return 0;
    return row.view.phase.*;
}

/// The spinner's frame at `turned`, a `phase`: `|`, `/`, `-` and `\` in turn. A constant. See
/// `phase` for how an owner's panel turns it.
pub fn spinner(turned: u32) []const u8 {
    const frames = [_][]const u8{ "|", "/", "-", "\\" };
    return frames[turned % frames.len];
}

// ---- the tables --------------------------------------------------------------------------------

/// `editor_vcs_jobs`: a row per job queued, running, or finished and not yet released (`JobRow`).
pub const jobs_table_name = "editor_vcs_jobs";
/// `editor_vcs_log`: a row per job that finished, the last `max_logged` (`LogRow`).
pub const log_table_name = "editor_vcs_log";
/// `editor_vcs_runner`: the runner's own row, one.
pub const state_table_name = "editor_vcs_runner";

/// Where a job is.
pub const JobState = enum(u8) {
    /// Waiting for its turn.
    queued,
    /// Its program was asked for, and the process system has not answered.
    starting,
    /// Its program runs.
    running,
    /// Its program ended, or never ran, and its owner was answered: kept until the owner
    /// releases it.
    finished,
};

/// A row of `editor_vcs_jobs`.
pub const JobRow = struct {
    /// The job's serial.
    serial: *u32,
    /// The owner's inbox, which the answer goes to.
    owner: *Atom,
    /// The tag the answer arrives under.
    reply_tag: *Atom,
    /// The owner's user data, which comes back with the answer.
    reply_user_data: *Table.Bytes,
    /// A `JobState`.
    state: *u8,
    /// An `Order`.
    order: *u8,
    /// The job's program, a `process.Process`; none until it runs.
    process: *u32,
    /// What `Job` gave, copied: the program and its arguments, its input, its variables.
    argv: *Table.String,
    input: *Table.String,
    environment: *Table.String,
    /// Where the program runs, absolute unless the owner gave a relative path.
    directory: *Table.String,
    /// The command line as a person reads it.
    shown: *Table.String,
};

/// A row of `editor_vcs_log`: a job that finished, or that never ran. What a person reads is
/// text.
pub const LogRow = struct {
    /// Counts the jobs logged, the latest the highest: the log's order.
    sequence: *u32,
    /// The job's serial.
    job: *u32,
    /// The owner's inbox.
    owner: *Atom,
    /// The command line as a person reads it.
    shown: *Table.String,
    /// Where it ran.
    directory: *Table.String,
    /// As `Finished.code`.
    code: *i32,
    /// As `Finished.started`.
    started: *u8,
    /// How it ended, or why it never ran, as a sentence.
    outcome: *Table.String,
    /// The first `max_logged_bytes` of what it said, and of its errors.
    said: *Table.String,
    errors: *Table.String,
    /// 1 when what it said, or its errors, ran past `max_logged_bytes` and was cut.
    said_cut: *u8,
    errors_cut: *u8,
};

/// The row of `editor_vcs_runner`.
const StateRow = struct {
    /// How far the spinner has turned.
    phase: *u32,
    /// The seconds heard since the spinner last turned.
    elapsed: *f32,
    /// The serial of the job last queued.
    serial: *u32,
    /// The sequence of the job last logged.
    logged: *u32,
};

const jobs_table = Atom.from(jobs_table_name);
const log_table = Atom.from(log_table_name);
const state_table = Atom.from(state_table_name);
const requests_table = Atom.from(requests_table_name);
const process_requests_table = Atom.from(process.commands_table_name);
const answers_table = Atom.from(plugin.app_commands.commands_table_name);
const time_subscriptions = Atom.from(time.subscriptions_table_name);
const places_table = Atom.from(mesha.os.places_table_name);

/// Makes the runner's tables, unless they are there: changes no row of one that is.
pub fn ensure(scratch: memory_mod.Scratch, atoms: *Atom.Registry, tables: *Table.Registry) !void {
    try atoms.tryInternAll(&.{ jobs_table_name, log_table_name, state_table_name });
    try Requests.ensure(scratch, atoms, tables, requests_table_name);

    var jobs: Table.Schema = undefined;
    try jobs.init(scratch.allocator, atoms, 12);
    defer jobs.deinit();
    try jobs.addFieldFallible("serial", u32, .int);
    try jobs.addFieldFallible("owner", Atom, .atom);
    try jobs.addFieldFallible("reply_tag", Atom, .atom);
    try jobs.addFieldFallible("reply_user_data", Table.Bytes, .bytes);
    try jobs.addFieldFallible("state", u8, .int);
    try jobs.addFieldFallible("order", u8, .int);
    try jobs.addFieldFallible("process", u32, .int);
    try jobs.addFieldFallible("argv", Table.String, .text_field);
    try jobs.addFieldFallible("input", Table.String, .text_field);
    try jobs.addFieldFallible("environment", Table.String, .text_field);
    try jobs.addFieldFallible("directory", Table.String, .text_field);
    try jobs.addFieldFallible("shown", Table.String, .text_field);
    _ = try tables.ensure(&jobs, max_running + max_unreleased, jobs_table, .durable);

    var log: Table.Schema = undefined;
    try log.init(scratch.allocator, atoms, 12);
    defer log.deinit();
    try log.addFieldFallible("sequence", u32, .int);
    try log.addFieldFallible("job", u32, .int);
    try log.addFieldFallible("owner", Atom, .atom);
    try log.addFieldFallible("shown", Table.String, .text_field);
    try log.addFieldFallible("directory", Table.String, .text_field);
    try log.addFieldFallible("code", i32, .int);
    try log.addFieldFallible("started", u8, .int);
    try log.addFieldFallible("outcome", Table.String, .text_field);
    try log.addFieldFallible("said", Table.String, .text_field);
    try log.addFieldFallible("errors", Table.String, .text_field);
    try log.addFieldFallible("said_cut", u8, .int);
    try log.addFieldFallible("errors_cut", u8, .int);
    _ = try tables.ensure(&log, max_logged, log_table, .durable);

    var state: Table.Schema = undefined;
    try state.init(scratch.allocator, atoms, 4);
    defer state.deinit();
    try state.addFieldFallible("phase", u32, .int);
    try state.addFieldFallible("elapsed", f32, .int);
    try state.addFieldFallible("serial", u32, .int);
    try state.addFieldFallible("logged", u32, .int);
    const defaults = .{ .phase = @as(u32, 0), .elapsed = @as(f32, 0), .serial = @as(u32, 0), .logged = @as(u32, 0) };
    _ = try tables.ensureSingleton(&state, state_table, defaults, .durable);
}

// ---- the system --------------------------------------------------------------------------------

const Msg = enum(u64) {
    /// The process system's answer to a job's spawn, a `process.SpawnedMsg`, the job's serial
    /// its user data.
    vcs_runner_spawned = Atom.from("vcs_runner_spawned").value(),
    /// A frame of the clock, a `time.FrameMsg`, heard while a program runs.
    vcs_runner_frame = Atom.from("vcs_runner_frame").value(),
    _,
};

/// Takes the process system's answers and the clock, then the frame's requests, finishes the
/// jobs whose programs ended, starts those whose turn came, and hears the clock while any
/// runs. Before the systems that own jobs in the editor's frame.
pub fn system() sequencer.System {
    return .{
        .name = "vcs_runner",
        .names = comptime &sequencer.enumNames(Msg),
        .root = Atom.from("vcs_runner"),
        .claims = claims,
        .active = active,
        .access = access,
        .kernels = &.{
            .{ .name = "vcs_runner.take_messages", .run = takeMessages },
            .{ .name = "vcs_runner.take_requests", .run = takeRequests },
            .{ .name = "vcs_runner.follow_jobs", .run = followJobs },
            .{ .name = "vcs_runner.start_jobs", .run = startJobs },
            .{ .name = "vcs_runner.subscribe", .run = subscribe },
        },
    };
}

fn claims(tag: Atom) bool {
    return switch (tag.to(Msg)) {
        _ => false,
        else => true,
    };
}

/// Whether a job in `state` has a program running, or asked for.
fn runs(state: u8) bool {
    return state == @intFromEnum(JobState.starting) or state == @intFromEnum(JobState.running);
}

/// Nothing to do while no job waits or runs and none is asked for: the system is off, and what
/// it heard of the clock with it.
fn active(frame: *const sequencer.Frame) bool {
    const requests = Requests.of(frame.memory, frame.tables, requests_table_name);
    if (requests.count() != 0) return true;
    const jobs = frame.tables.findByName(jobs_table) orelse return false;
    var rows = jobs.readQuery(struct { state: *u8 });
    while (rows.next()) |row| {
        if (row.view.state.* != @intFromEnum(JobState.finished)) return true;
    }
    return false;
}

fn access(frame: *const sequencer.Frame) sequencer.Access {
    const tables = frame.tables;
    var result: sequencer.Access = .{};
    result.write(jobs_table);
    result.write(log_table);
    result.write(state_table);
    result.write(requests_table);
    result.writeIfPresent(tables, process_requests_table);
    // The answers go through the editor's hook.
    result.writeIfPresent(tables, answers_table);
    result.writeIfPresent(tables, time_subscriptions);
    // A job given no directory runs in the working directory.
    result.read(places_table);
    // How each running program is doing, and what it said, are read from its own table.
    const jobs = tables.findByName(jobs_table) orelse return result;
    var rows = jobs.readQuery(struct { state: *u8, process: *u32 });
    while (rows.next()) |row| {
        if (row.view.state.* != @intFromEnum(JobState.running)) continue;
        process.declareProcess(&result, tables, @enumFromInt(row.view.process.*));
    }
    return result;
}

/// The process system's answers to the spawns, and the clock's frames.
fn takeMessages(pass: *sequencer.Pass) !void {
    const frame = pass.frame;
    if (frame.messages.len == 0) return;
    const work = try Work.of(pass);
    for (frame.messages) |received| {
        switch (received.tag.to(Msg)) {
            .vcs_runner_spawned => {
                const spawned = received.payloadAs(process.SpawnedMsg) catch |err| {
                    received.unreadable(err);
                    continue;
                };
                const serial = received.userDataAs(u32) catch |err| {
                    received.unreadable(err);
                    continue;
                };
                try work.takeSpawned(serial.*, spawned.*);
            },
            .vcs_runner_frame => {
                const frame_time = received.payloadAs(time.FrameMsg) catch |err| {
                    received.unreadable(err);
                    continue;
                };
                try work.turn(frame_time.raw_dt);
            },
            _ => {},
        }
    }
}

/// The frame's requests, in the order appended.
fn takeRequests(pass: *sequencer.Pass) !void {
    const requests = Requests.of(pass.frame.memory, pass.frame.tables, requests_table_name);
    if (requests.count() == 0) return;
    var work = try Work.of(pass);
    try requests.take(pass, &work, Work.apply);
}

/// Finishes each job whose program has ended, as its table says. The table is read rather
/// than `events.process`, which keeps only its latest events, so a program whose `exited` a
/// busy frame pushed out is still seen to end. A program asked for this frame is looked at
/// from the next, once its table is declared.
fn followJobs(pass: *sequencer.Pass) !void {
    const work = try Work.of(pass);
    const tables = pass.frame.tables;
    var ended: [max_running]Ended = undefined;
    var ended_count: usize = 0;
    var rows = work.jobs.readQuery(struct { serial: *u32, state: *u8, process: *u32 });
    while (rows.next()) |row| {
        if (row.view.state.* != @intFromEnum(JobState.running)) continue;
        const program: process.Process = @enumFromInt(row.view.process.*);
        const code = exitCode(pass, tables, program) orelse continue;
        if (ended_count == ended.len) break;
        ended[ended_count] = .{ .serial = row.view.serial.*, .code = code };
        ended_count += 1;
    }
    for (ended[0..ended_count]) |finished| try work.finish(finished.serial, finished.code);
}

const Ended = struct { serial: u32, code: i32 };

/// `program`'s exit code once it has ended; -1 when the process system no longer knows it, as
/// it ended unseen and how is not known; null while it runs or its table is not declared.
fn exitCode(pass: *const sequencer.Pass, tables: *Table.Registry, program: process.Process) ?i32 {
    const child_table = process.tableOf(tables, program) orelse return -1;
    if (!pass.declares(child_table.name)) return null;
    const child = process.rowOf(tables, program) orelse return -1;
    if (child.state.* != @intFromEnum(process.State.exited)) return null;
    return child.exit_code.*;
}

/// Starts the queued jobs whose turn came, in the order queued, while fewer than `max_running`
/// run.
fn startJobs(pass: *sequencer.Pass) !void {
    const work = try Work.of(pass);
    const job_count = work.jobs.count();
    if (job_count == 0) return;
    const scratch = try pass.frame.memory.frameScratchAllocator();
    const waiting = try scratch.allocator.alloc(Waiting, job_count);
    const owners = try scratch.allocator.alloc(OwnerTally, job_count);
    var waiting_count: usize = 0;
    var owner_count: usize = 0;
    var running_count: usize = 0;
    var rows = work.jobs.readQuery(struct { serial: *u32, owner: *Atom, state: *u8, order: *u8 });
    while (rows.next()) |row| {
        const tally = tallyOf(owners, &owner_count, row.view.owner.*);
        if (runs(row.view.state.*)) {
            running_count += 1;
            tally.runs += 1;
            if (row.view.order.* == @intFromEnum(Order.alone)) tally.alone_runs = true;
            continue;
        }
        if (row.view.state.* != @intFromEnum(JobState.queued)) continue;
        waiting[waiting_count] = .{ .handle = row.handle, .serial = row.view.serial.*, .owner = row.view.owner.*, .order = row.view.order.* };
        waiting_count += 1;
    }
    std.mem.sort(Waiting, waiting[0..waiting_count], {}, Waiting.queuedBefore);
    for (waiting[0..waiting_count]) |job| {
        if (running_count >= max_running) break;
        const tally = tallyOf(owners, &owner_count, job.owner);
        if (tally.held) continue;
        // An owner's job that waits holds every later one of that owner, so its jobs start in
        // the order queued.
        const alone = job.order == @intFromEnum(Order.alone);
        if (tally.alone_runs or (alone and tally.runs != 0)) {
            tally.held = true;
            continue;
        }
        try work.start(job.handle);
        running_count += 1;
        tally.runs += 1;
        if (alone) tally.alone_runs = true;
    }
}

/// A queued job, as `startJobs` takes them in turn.
const Waiting = struct {
    handle: Table.RowHandle,
    serial: u32,
    owner: Atom,
    order: u8,

    fn queuedBefore(_: void, a: Waiting, b: Waiting) bool {
        return a.serial < b.serial;
    }
};

/// What `startJobs` knows of an owner's jobs: how many run, whether one that runs is alone,
/// and whether one of its jobs waits, which holds its later ones.
const OwnerTally = struct { owner: Atom, runs: u32 = 0, alone_runs: bool = false, held: bool = false };

/// `owner`'s tally among the first `count.*` of `owners`, added when it is not there.
fn tallyOf(owners: []OwnerTally, count: *usize, owner: Atom) *OwnerTally {
    for (owners[0..count.*]) |*tally| {
        if (tally.owner == owner) return tally;
    }
    owners[count.*] = .{ .owner = owner };
    count.* += 1;
    return &owners[count.* - 1];
}

/// Hears the clock's frames while a program runs, to turn the spinner; nothing otherwise.
fn subscribe(pass: *sequencer.Pass) !void {
    if (!pass.writes(time_subscriptions)) return;
    var rows = try pass.rows(jobs_table, struct { state: *u8 });
    var jobs = rows.read();
    while (jobs.next()) |row| {
        if (!runs(row.view.state.*)) continue;
        const inbox = sequencer.inboxOf(system());
        _ = try pass.append(time_subscriptions, .{ .kind = time.SubscriptionKind.frame, .inbox = inbox, .tag = Atom.from(Msg.vcs_runner_frame) });
        return;
    }
}

/// What the kernels hand their helpers: the run's pass, and the jobs and the log as the run
/// writes them.
const Work = struct {
    pass: *sequencer.Pass,
    jobs: *Table,
    log: *Table,

    fn of(pass: *sequencer.Pass) !Work {
        return .{ .pass = pass, .jobs = try pass.writeTable(jobs_table), .log = try pass.writeTable(log_table) };
    }

    fn tables(work: Work) *Table.Registry {
        return work.pass.frame.tables;
    }

    fn requestProcess(work: Work, wanted: process.CmdPayload) void {
        const registry = work.tables();
        process.request(registry.memory, registry, wanted);
    }

    fn apply(work: *Work, wanted: *const Request) !void {
        switch (wanted.*) {
            .run => |job| try work.queue(job),
            .release => |serial| {
                const handle = findJob(work.jobs, serial) orelse return;
                work.forget(handle);
            },
            .give_up => |owner| try work.giveUpJobs(owner),
        }
    }

    /// Adds `job` to the queue, under the next serial.
    fn queue(work: Work, job: Job) !void {
        const state = try work.pass.writeSingleton(state_table, StateRow);
        state.serial.* +%= 1;
        if (state.serial.* == 0) state.serial.* = 1;
        const scratch = try work.pass.frame.memory.frameScratchAllocator();
        const directory = if (job.directory.len != 0) job.directory else open.places(work.pass).working_directory;
        const shown = if (job.shown.len != 0) job.shown else try spacedArguments(scratch.allocator, job.argv);
        _ = try work.pass.append(jobs_table, .{
            .serial = state.serial.*,
            .owner = job.owner.inbox,
            .reply_tag = job.owner.tag,
            .reply_user_data = job.owner.user_data.bytes,
            .state = @as(u8, @intFromEnum(JobState.queued)),
            .order = @as(u8, @intFromEnum(job.order)),
            .process = @as(u32, 0),
            .argv = job.argv,
            .input = job.input,
            .environment = job.environment,
            .directory = directory,
            .shown = shown,
        });
    }

    /// Lets every job of `owner` go, answering for none.
    fn giveUpJobs(work: Work, owner: Atom) !void {
        const scratch = try work.pass.frame.memory.frameScratchAllocator();
        const handles = try scratch.allocator.alloc(Table.RowHandle, work.jobs.count());
        var count: usize = 0;
        var rows = work.jobs.readQuery(struct { owner: *Atom });
        while (rows.next()) |row| {
            if (row.view.owner.* != owner) continue;
            handles[count] = row.handle;
            count += 1;
        }
        for (handles[0..count]) |handle| work.forget(handle);
    }

    /// Lets the job at `handle` go with its program, which is ended if it still runs. A job
    /// whose program was asked for and has not answered is forgotten: the answer then finds
    /// no job and lets its program go.
    fn forget(work: Work, handle: Table.RowHandle) void {
        const job = work.jobs.readRow(handle, struct { process: *u32 }) orelse return;
        const program: process.Process = @enumFromInt(job.process.*);
        if (program != .none) work.requestProcess(.{ .release = program });
        work.jobs.free(handle);
        // Its copied text is dead: shed once no run holds the table.
        work.jobs.compact_payloads_wanted = true;
    }

    /// Runs the job at `handle`'s program, its input piped when it has some; the answer names
    /// the job by its serial.
    fn start(work: Work, handle: Table.RowHandle) !void {
        const job = work.jobs.getRow(handle, JobRow) orelse return;
        const serial = job.serial.*;
        const input = work.jobs.textOf(job.input.*);
        const reply = sequencer.ReplyTo.of(system(), .from(Msg.vcs_runner_spawned)).with(.of(&serial));
        work.requestProcess(.{ .spawn = .{
            .argv = work.jobs.textOf(job.argv.*),
            .cwd = work.jobs.textOf(job.directory.*),
            .environment = work.jobs.textOf(job.environment.*),
            .stdin = if (input.len == 0) .ignore else .pipe,
            .stdout = .pipe,
            .stderr = .pipe,
            .reply = reply,
        } });
        job.state.* = @intFromEnum(JobState.starting);
    }

    /// The process system's answer to the spawn of job `serial`: the program runs, and is
    /// given its input, or the job finishes here, never run, and is kept for its owner to
    /// release.
    fn takeSpawned(work: Work, serial: u32, spawned: process.SpawnedMsg) !void {
        const handle = findJob(work.jobs, serial) orelse return work.unwanted(spawned);
        const row = work.jobs.getRow(handle, JobRow) orelse return work.unwanted(spawned);
        if (row.state.* != @intFromEnum(JobState.starting)) return work.unwanted(spawned);
        if (spawned.result != .spawned) {
            var outcome_buffer: [max_unstarted_bytes]u8 = undefined;
            const argv = work.jobs.textOf(row.argv.*);
            const outcome = describeUnstarted(&outcome_buffer, argv, spawned.result);
            try work.appendLog(row, -1, spawned.result, outcome, "", "");
            work.answer(row, .{ .job = serial, .code = -1, .started = @intFromEnum(spawned.result) });
            // Kept, with no program, for its owner to read as empty and release.
            row.state.* = @intFromEnum(JobState.finished);
            return work.releaseUnread();
        }
        row.state.* = @intFromEnum(JobState.running);
        row.process.* = @intFromEnum(spawned.process);
        const input = work.jobs.textOf(row.input.*);
        if (input.len == 0) return;
        work.requestProcess(.{ .write = .{ .process = spawned.process, .bytes = input } });
        work.requestProcess(.{ .close_input = spawned.process });
    }

    /// A program asked for a job given up or released while it started: not wanted.
    fn unwanted(work: Work, spawned: process.SpawnedMsg) void {
        if (spawned.result == .spawned) work.requestProcess(.{ .release = spawned.process });
    }

    /// The program of job `serial` ended with `code`: it is logged, its owner answered, and the
    /// job kept for its owner to read and release.
    fn finish(work: Work, serial: u32, code: i32) !void {
        const handle = findJob(work.jobs, serial) orelse return;
        const job = work.jobs.getRow(handle, JobRow) orelse return;
        const program: process.Process = @enumFromInt(job.process.*);
        const kept = process.outputOf(work.tables(), program);
        const said = if (kept) |found| found.after(.stdout, 0) else "";
        const errors = if (kept) |found| found.after(.stderr, 0) else "";
        var outcome_buffer: [64]u8 = undefined;
        const outcome = describeExit(&outcome_buffer, code, builtin.os.tag);
        try work.appendLog(job, code, .spawned, outcome, said, errors);
        work.answer(job, .{ .job = serial, .code = code, .started = @intFromEnum(process.SpawnResult.spawned) });
        job.state.* = @intFromEnum(JobState.finished);
        try work.releaseUnread();
    }

    /// Past `max_unreleased` finished jobs, releases the oldest, which its owner did not.
    fn releaseUnread(work: Work) !void {
        while (true) {
            var finished_count: usize = 0;
            var oldest: ?Table.RowHandle = null;
            var oldest_serial: u32 = 0;
            var oldest_owner: Atom = sequencer.no_inbox;
            var rows = work.jobs.readQuery(struct { serial: *u32, owner: *Atom, state: *u8 });
            while (rows.next()) |row| {
                if (row.view.state.* != @intFromEnum(JobState.finished)) continue;
                finished_count += 1;
                if (oldest != null and oldest_serial < row.view.serial.*) continue;
                oldest = row.handle;
                oldest_serial = row.view.serial.*;
                oldest_owner = row.view.owner.*;
            }
            if (finished_count <= max_unreleased) return;
            Log.warn("job_released_unread", .{ .owner = oldest_owner, .job = oldest_serial });
            work.forget(oldest.?);
        }
    }

    /// Answers `job`'s owner with `finished`, through the editor's hook, which copies it.
    fn answer(work: Work, job: JobRow, finished: Finished) void {
        const user_data = work.jobs.bytesOf(job.reply_user_data.*);
        const reply: sequencer.ReplyTo = .{ .inbox = job.owner.*, .tag = job.reply_tag.*, .user_data = .{ .bytes = user_data } };
        const registry = work.tables();
        plugin.app_commands.request(registry.memory, registry, .{ .answer = .{ .reply = reply, .payload = std.mem.asBytes(&finished) } });
    }

    /// Logs `job`, which ended as `outcome` says, the oldest entry going once `max_logged` are
    /// kept.
    fn appendLog(work: Work, job: JobRow, code: i32, started: process.SpawnResult, outcome: []const u8, said: []const u8, errors: []const u8) !void {
        const state = try work.pass.writeSingleton(state_table, StateRow);
        state.logged.* +%= 1;
        if (work.log.count() >= max_logged) work.dropOldestLog();
        const said_kept = said[0..utf8Cut(said, max_logged_bytes)];
        const errors_kept = errors[0..utf8Cut(errors, max_logged_bytes)];
        _ = try work.pass.append(log_table, .{
            .sequence = state.logged.*,
            .job = job.serial.*,
            .owner = job.owner.*,
            .shown = work.jobs.textOf(job.shown.*),
            .directory = work.jobs.textOf(job.directory.*),
            .code = code,
            .started = @as(u8, @intFromEnum(started)),
            .outcome = outcome,
            .said = said_kept,
            .errors = errors_kept,
            .said_cut = @as(u8, @intFromBool(said.len > max_logged_bytes)),
            .errors_cut = @as(u8, @intFromBool(errors.len > max_logged_bytes)),
        });
    }

    fn dropOldestLog(work: Work) void {
        var oldest: ?Table.RowHandle = null;
        var oldest_sequence: u32 = 0;
        var rows = work.log.readQuery(struct { sequence: *u32 });
        while (rows.next()) |row| {
            if (oldest != null and oldest_sequence < row.view.sequence.*) continue;
            oldest = row.handle;
            oldest_sequence = row.view.sequence.*;
        }
        work.log.free(oldest orelse return);
        // Its text is dead: shed once no run holds the table.
        work.log.compact_payloads_wanted = true;
    }

    /// Turns the spinner once for each `phase_step_seconds` heard, `seconds` more.
    fn turn(work: Work, seconds: f32) !void {
        const state = try work.pass.writeSingleton(state_table, StateRow);
        const elapsed = state.elapsed.* + @max(seconds, 0);
        const steps = @floor(elapsed / phase_step_seconds);
        // Only the step within a turn shows: a long frame need not count every step.
        const shown_steps: u32 = @intFromFloat(@mod(steps, 4));
        state.phase.* +%= shown_steps;
        state.elapsed.* = elapsed - steps * phase_step_seconds;
    }
};

/// The row of the job `serial`; null when the runner has none.
fn findJob(jobs: *Table, serial: u32) ?Table.RowHandle {
    var rows = jobs.readQuery(struct { serial: *u32 });
    while (rows.next()) |row| {
        if (row.view.serial.* == serial) return row.handle;
    }
    return null;
}

/// How many bytes of `text` fit in `limit` without cutting a UTF-8 character: all of it when it
/// fits, else up to the last character boundary at or before `limit`.
fn utf8Cut(text: []const u8, limit: usize) usize {
    if (text.len <= limit) return text.len;
    var cut = limit;
    while (cut > 0 and text[cut] & 0xc0 == 0x80) cut -= 1;
    return cut;
}

/// `argv`, its arguments separated by spaces, in `allocator`: a command line as a person reads
/// it.
fn spacedArguments(allocator: std.mem.Allocator, argv: []const u8) ![]const u8 {
    const spaced = try allocator.dupe(u8, argv);
    std.mem.replaceScalar(u8, spaced, process.argument_separator, ' ');
    return spaced;
}

/// How a program that ended with `code` ended, as a sentence, in `buffer`: on `os_tag`, which
/// has no signals on Windows, a negative code is an exit code.
fn describeExit(buffer: []u8, code: i32, os_tag: std.Target.Os.Tag) []const u8 {
    if (code == 0) return "finished";
    if (code == -1) return "ended, how is not known";
    const signalled = code < 0 and os_tag != .windows;
    if (signalled) return std.fmt.bufPrint(buffer, "ended by signal {d}", .{-code}) catch "ended by a signal";
    return std.fmt.bufPrint(buffer, "exited with code {d}", .{code}) catch "exited with an error";
}

/// Room for `describeUnstarted`'s sentence: a program's path, as long as the resources system
/// takes one, and the longest reason.
const max_unstarted_bytes = mesha.resources.max_path + 64;

/// Why a job whose `argv` names its program never ran, as a sentence, in `buffer`, which holds
/// `max_unstarted_bytes`.
fn describeUnstarted(buffer: []u8, argv: []const u8, result: process.SpawnResult) []const u8 {
    const program_end = std.mem.indexOfScalar(u8, argv, process.argument_separator) orelse argv.len;
    const program = argv[0..program_end];
    const reason: []const u8 = switch (result) {
        .spawned => "ran",
        .not_found => "was not found",
        .access_denied => "may not be run",
        .bad_arguments => "could not be given its arguments or its variables",
        .too_many_processes => "was not started: too many programs are running",
        .out_of_memory => "was not started: memory ran out",
        .failed => "could not be started",
    };
    return std.fmt.bufPrint(buffer, "{s} {s}", .{ program, reason }) catch reason;
}
