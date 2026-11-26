//! Tests of the version-control panels' runner (`runner.zig`) over the real process system, as
//! the host runs it, with stand-in programs (`sh`, `cat`, `printf`, `sleep`) in place of git's:
//! skipped on Windows, which has none of them.

const std = @import("std");
const builtin = @import("builtin");
const mesha = @import("mesha");
const mesha_runtime = @import("mesha_runtime");
const Atom = mesha.Atom;
const Table = mesha.Table;
const memory_mod = mesha.memory;
const plugin = mesha.plugin;
const process = mesha.process;
const sequencer = mesha.sequencer;
const time = mesha.time;
const editor = @import("../editor.zig");
const editor_sequencer = @import("../editor_sequencer.zig");
const runner = @import("runner.zig");
const process_runtime = mesha_runtime.process;
const testing = std.testing;

fn noAccess(frame: *const sequencer.Frame) sequencer.Access {
    _ = frame;
    return .{};
}

/// A system that runs nothing, whose inbox a job's answer goes to.
fn ownerSystem(comptime name: []const u8) sequencer.System {
    return .{ .name = name, .root = Atom.from(name), .claims = sequencer.claims_nothing, .access = noAccess, .kernels = &.{} };
}

const first_owner = ownerSystem("vcs_test_owner");
const second_owner = ownerSystem("vcs_test_other_owner");

/// The tag the owners hear their answers under.
const finished_tag = Atom.from("vcs_test_finished");

/// The runner over the real process system, with a temporary directory for its programs to
/// write in.
const Bench = struct {
    memory: memory_mod.Memory = undefined,
    atoms: Atom.Registry = undefined,
    tables: Table.Registry = undefined,
    processes: process_runtime.Processes = undefined,
    folder: testing.TmpDir = undefined,
    directory_buffer: [std.fs.max_path_bytes]u8 = undefined,
    /// The temporary directory's path, absolute.
    directory: []const u8 = "",

    fn init(bench: *Bench) !void {
        bench.folder = testing.tmpDir(.{});
        const directory_length = try bench.folder.dir.realPath(testing.io, &bench.directory_buffer);
        bench.directory = bench.directory_buffer[0..directory_length];
        bench.memory.init(testing.allocator);
        try bench.atoms.init(&bench.memory);
        try bench.tables.init(&bench.memory, 64);
        try sequencer.ensure(try bench.memory.tableScratchAllocator(), &bench.atoms, &bench.tables);
        try process_runtime.ensure(try bench.memory.tableScratchAllocator(), &bench.atoms, &bench.tables);
        try time.ensureTables(try bench.memory.tableScratchAllocator(), &bench.atoms, &bench.tables);
        try plugin.app_commands.Requests.ensure(try bench.memory.tableScratchAllocator(), &bench.atoms, &bench.tables, plugin.app_commands.commands_table_name);
        try runner.ensure(try bench.memory.tableScratchAllocator(), &bench.atoms, &bench.tables);
        const everyone: sequencer.Sequencer = .{ .name = "vcs_runner_test", .steps = &.{
            .{ .system = runner.system() },
            .{ .system = first_owner },
            .{ .system = second_owner },
        } };
        try sequencer.ensureInboxes(try bench.memory.tableScratchAllocator(), &bench.atoms, &bench.tables, &everyone);
        var starting_environment = try testing.environ.createMap(testing.allocator);
        defer starting_environment.deinit();
        try bench.processes.init(testing.allocator, &bench.memory, testing.io, &starting_environment);
    }

    fn deinit(bench: *Bench) void {
        bench.processes.deinit(&bench.tables);
        bench.tables.deinit();
        bench.atoms.deinit();
        bench.memory.deinit();
        bench.folder.cleanup();
    }

    /// One frame as the host runs it: what the programs did is delivered, the runner runs, the
    /// process system applies its requests, and the editor's hook delivers the answers.
    fn step(bench: *Bench) void {
        bench.stepAnswering(.deliver);
    }

    /// What `stepAnswering` does with the answers the runner gave.
    const Answers = enum {
        /// The editor's hook delivers them, as after each run.
        deliver,
        /// They wait in `commands.app`, as for an owner that runs before they are delivered.
        hold,
    };

    fn stepAnswering(bench: *Bench, answers_wanted: Answers) void {
        bench.processes.deliver(&bench.tables);
        const solo = sequencer.Solo.of("vcs_runner_test", runner.system());
        editor_sequencer.run(&bench.memory, &bench.atoms, &bench.tables, &solo.sequencer(), null);
        process_runtime.applyCommands(&bench.memory, &bench.atoms, &bench.tables, &bench.processes);
        if (answers_wanted == .deliver) {
            const answers = plugin.app_commands.Requests.of(&bench.memory, &bench.tables, plugin.app_commands.commands_table_name);
            answers.drain(bench, deliverAnswer);
        }
        bench.tables.reclaimPayloads();
    }

    fn deliverAnswer(bench: *Bench, payload: *plugin.app_commands.Payload) sequencer.Applied {
        return editor.processCmd(&bench.tables, &bench.atoms, payload);
    }

    fn reply(owner: sequencer.System) sequencer.ReplyTo {
        return sequencer.ReplyTo.of(owner, finished_tag);
    }

    /// The oldest answer `owner` has not taken; null when there is none.
    fn answerTo(bench: *Bench, owner: sequencer.System) !?runner.Finished {
        const inbox = bench.tables.findByName(sequencer.inboxOf(owner)) orelse return null;
        const received = sequencer.takeOldest(inbox) orelse return null;
        try testing.expectEqual(finished_tag, received.tag);
        const finished = try received.payloadAs(runner.Finished);
        return finished.*;
    }

    /// Runs frames until `owner` is answered, or fails after a few seconds.
    fn awaitAnswer(bench: *Bench, owner: sequencer.System) !runner.Finished {
        for (0..500) |_| {
            bench.step();
            if (try bench.answerTo(owner)) |finished| return finished;
            try testing.io.sleep(.fromMilliseconds(10), .awake);
        }
        return error.Timeout;
    }

    /// How many of `owner`'s jobs run, or wait for the process system to start them.
    fn runningCount(bench: *Bench, owner: Atom) usize {
        const jobs = bench.tables.findByName(Atom.from(runner.jobs_table_name)) orelse return 0;
        var rows = jobs.readQuery(struct { owner: *Atom, state: *u8 });
        var count: usize = 0;
        while (rows.next()) |row| {
            if (row.view.owner.* != owner) continue;
            const state: runner.JobState = @enumFromInt(row.view.state.*);
            if (state == .starting or state == .running) count += 1;
        }
        return count;
    }

    /// The program of the job `job`; none while it has none.
    fn programOf(bench: *Bench, job: u32) process.Process {
        const jobs = bench.tables.findByName(Atom.from(runner.jobs_table_name)) orelse return .none;
        var rows = jobs.readQuery(struct { serial: *u32, process: *u32 });
        while (rows.next()) |row| {
            if (row.view.serial.* == job) return @enumFromInt(row.view.process.*);
        }
        return .none;
    }

    /// The serial of `owner`'s job that runs; 0 when none does.
    fn runningJob(bench: *Bench, owner: Atom) u32 {
        return bench.jobIn(owner, .running);
    }

    /// The serial of a job of `owner`'s in `state`; 0 when none is.
    fn jobIn(bench: *Bench, owner: Atom, state: runner.JobState) u32 {
        const jobs = bench.tables.findByName(Atom.from(runner.jobs_table_name)) orelse return 0;
        var rows = jobs.readQuery(struct { serial: *u32, owner: *Atom, state: *u8 });
        while (rows.next()) |row| {
            if (row.view.owner.* == owner and row.view.state.* == @intFromEnum(state)) return row.view.serial.*;
        }
        return 0;
    }

    /// The log's latest entry, as a person reads it.
    fn newestLog(bench: *Bench) !Logged {
        const log = bench.tables.findByName(Atom.from(runner.log_table_name)) orelse return error.NoLog;
        var rows = log.readQuery(struct { sequence: *u32, shown: []const u8, code: *i32, outcome: []const u8, said: []const u8, errors: []const u8 });
        var newest: ?Logged = null;
        var newest_sequence: u32 = 0;
        while (rows.next()) |row| {
            if (newest != null and row.view.sequence.* < newest_sequence) continue;
            newest_sequence = row.view.sequence.*;
            newest = .{ .shown = row.view.shown, .code = row.view.code.*, .outcome = row.view.outcome, .said = row.view.said, .errors = row.view.errors };
        }
        return newest orelse error.NoLog;
    }

    /// The tag the runner hears the clock's frames under; null while it hears none.
    fn frameTag(bench: *Bench) ?Atom {
        const subscriptions = bench.tables.findByName(Atom.from(time.subscriptions_table_name)) orelse return null;
        var rows = subscriptions.readQuery(struct { kind: *time.SubscriptionKind, inbox: *Atom, tag: *Atom });
        while (rows.next()) |row| {
            if (row.view.inbox.* == sequencer.inboxOf(runner.system()) and row.view.kind.* == .frame) return row.view.tag.*;
        }
        return null;
    }
};

const Logged = struct { shown: []const u8, code: i32, outcome: []const u8, said: []const u8, errors: []const u8 };

test "jobs of one owner marked alone run one at a time, in order" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    const owner = sequencer.inboxOf(first_owner);
    const other = sequencer.inboxOf(second_owner);

    const writers = [_][]const u8{
        "sh\x1f-c\x1fsleep 0.1; printf a >> written",
        "sh\x1f-c\x1fsleep 0.1; printf b >> written",
        "sh\x1f-c\x1fsleep 0.1; printf c >> written",
    };
    for (writers) |argv| runner.run(&bench.memory, &bench.tables, .{ .owner = Bench.reply(first_owner), .argv = argv, .directory = bench.directory, .order = .alone });
    runner.run(&bench.memory, &bench.tables, .{ .owner = Bench.reply(second_owner), .argv = "sleep\x1f0.3" });

    // The owner's first runs, and the other owner's beside it.
    bench.step();
    try testing.expectEqual(@as(usize, 1), bench.runningCount(owner));
    try testing.expectEqual(@as(usize, 1), bench.runningCount(other));

    var answered: usize = 0;
    for (0..500) |_| {
        bench.step();
        try testing.expect(bench.runningCount(owner) <= 1);
        while (try bench.answerTo(first_owner)) |finished| {
            try testing.expectEqual(@as(i32, 0), finished.code);
            answered += 1;
        }
        if (answered == writers.len) break;
        try testing.io.sleep(.fromMilliseconds(10), .awake);
    } else return error.Timeout;
    const written = try bench.folder.dir.readFileAlloc(testing.io, "written", testing.allocator, .limited(16));
    defer testing.allocator.free(written);
    try testing.expectEqualStrings("abc", written);
}

test "a finished job answers its owner with the code and what it said" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();

    runner.run(&bench.memory, &bench.tables, .{ .owner = Bench.reply(first_owner), .argv = "sh\x1f-c\x1fprintf out; printf err >&2; exit 3", .shown = "git status" });
    const finished = try bench.awaitAnswer(first_owner);
    try testing.expectEqual(@as(i32, 3), finished.code);
    try testing.expectEqual(@as(u8, @intFromEnum(process.SpawnResult.spawned)), finished.started);
    const said = runner.output(&bench.tables, finished.job).?;
    try testing.expectEqualStrings("out", said.said);
    try testing.expectEqualStrings("err", said.errors);
    const logged = try bench.newestLog();
    try testing.expectEqualStrings("git status", logged.shown);
    try testing.expectEqual(@as(i32, 3), logged.code);
    try testing.expectEqualStrings("exited with code 3", logged.outcome);
    try testing.expectEqualStrings("out", logged.said);
    try testing.expectEqualStrings("err", logged.errors);

    // Released, the job's program is gone, and the log keeps what it said.
    const program = bench.programOf(finished.job);
    try testing.expect(program != .none);
    runner.release(&bench.memory, &bench.tables, finished.job);
    bench.step();
    try testing.expect(process.tableOf(&bench.tables, program) == null);
    try testing.expect(runner.output(&bench.tables, finished.job) == null);
    try testing.expectEqualStrings("out", (try bench.newestLog()).said);

    // A job's input is written to its program, and closed.
    runner.run(&bench.memory, &bench.tables, .{ .owner = Bench.reply(first_owner), .argv = "cat", .input = "hello" });
    const echoed = try bench.awaitAnswer(first_owner);
    try testing.expectEqual(@as(i32, 0), echoed.code);
    try testing.expectEqualStrings("hello", runner.output(&bench.tables, echoed.job).?.said);
    try testing.expectEqualStrings("cat", (try bench.newestLog()).shown);
    runner.release(&bench.memory, &bench.tables, echoed.job);

    // A program that is not there never runs, and the log says why.
    runner.run(&bench.memory, &bench.tables, .{ .owner = Bench.reply(first_owner), .argv = "mesha-no-such-program\x1f--version" });
    const refused = try bench.awaitAnswer(first_owner);
    try testing.expectEqual(@as(u8, @intFromEnum(process.SpawnResult.not_found)), refused.started);
    try testing.expectEqual(@as(i32, -1), refused.code);
    const refusal = try bench.newestLog();
    try testing.expectEqualStrings("mesha-no-such-program --version", refusal.shown);
    try testing.expectEqualStrings("mesha-no-such-program was not found", refusal.outcome);
    try testing.expect(!runner.busy(&bench.tables, sequencer.inboxOf(first_owner)));
    // Kept, empty, until it is released, so an answer for it is not taken for one given up.
    const unsaid = runner.output(&bench.tables, refused.job).?;
    try testing.expectEqualStrings("", unsaid.said);
    runner.release(&bench.memory, &bench.tables, refused.job);
    bench.step();
    try testing.expect(runner.output(&bench.tables, refused.job) == null);
}

test "giving up releases a job that does not end, and the next job runs" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    const owner = sequencer.inboxOf(first_owner);

    runner.run(&bench.memory, &bench.tables, .{ .owner = Bench.reply(first_owner), .argv = "sleep\x1f30", .order = .alone });
    for (0..500) |_| {
        bench.step();
        if (bench.runningJob(owner) != 0) break;
        try testing.io.sleep(.fromMilliseconds(10), .awake);
    } else return error.Timeout;
    const stuck = bench.runningJob(owner);
    const stuck_program = bench.programOf(stuck);
    try testing.expect(runner.busy(&bench.tables, owner));
    try testing.expectEqualStrings("sleep 30", runner.running(&bench.tables, owner));

    runner.giveUp(&bench.memory, &bench.tables, owner);
    runner.run(&bench.memory, &bench.tables, .{ .owner = Bench.reply(first_owner), .argv = "printf\x1fdone", .order = .alone });
    const finished = try bench.awaitAnswer(first_owner);
    try testing.expect(finished.job != stuck);
    try testing.expectEqual(@as(i32, 0), finished.code);
    try testing.expectEqualStrings("done", runner.output(&bench.tables, finished.job).?.said);
    try testing.expect(try bench.answerTo(first_owner) == null);

    // The program given up was ended, and let go.
    for (0..500) |_| {
        if (process.tableOf(&bench.tables, stuck_program) == null) break;
        bench.step();
        try testing.io.sleep(.fromMilliseconds(10), .awake);
    } else return error.Timeout;
    try testing.expect(try bench.answerTo(first_owner) == null);
    runner.release(&bench.memory, &bench.tables, finished.job);
    bench.step();
    try testing.expect(!runner.busy(&bench.tables, owner));

    // An answer given before a give-up is taken still arrives, the frame after: its job is
    // gone, and the owner drops it.
    runner.run(&bench.memory, &bench.tables, .{ .owner = Bench.reply(first_owner), .argv = "printf\x1flate" });
    for (0..500) |_| {
        bench.stepAnswering(.hold);
        if (bench.jobIn(owner, .finished) != 0) break;
        try testing.io.sleep(.fromMilliseconds(10), .awake);
    } else return error.Timeout;
    const late = bench.jobIn(owner, .finished);
    runner.giveUp(&bench.memory, &bench.tables, owner);
    bench.step();
    const answered_late = (try bench.answerTo(first_owner)) orelse return error.NoAnswer;
    try testing.expectEqual(late, answered_late.job);
    try testing.expect(runner.output(&bench.tables, answered_late.job) == null);
}

test "a shared job queued behind its owner's alone job waits for it" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    const owner = sequencer.inboxOf(first_owner);

    runner.run(&bench.memory, &bench.tables, .{ .owner = Bench.reply(first_owner), .argv = "sh\x1f-c\x1fsleep 0.1; printf a >> written", .directory = bench.directory, .order = .alone });
    runner.run(&bench.memory, &bench.tables, .{ .owner = Bench.reply(first_owner), .argv = "sh\x1f-c\x1fprintf b >> written", .directory = bench.directory });
    bench.step();
    try testing.expectEqual(@as(usize, 1), bench.runningCount(owner));
    try testing.expect(bench.jobIn(owner, .queued) != 0);

    var answered: usize = 0;
    for (0..500) |_| {
        bench.step();
        try testing.expect(bench.runningCount(owner) <= 1);
        while (try bench.answerTo(first_owner)) |_| answered += 1;
        if (answered == 2) break;
        try testing.io.sleep(.fromMilliseconds(10), .awake);
    } else return error.Timeout;
    const written = try bench.folder.dir.readFileAlloc(testing.io, "written", testing.allocator, .limited(16));
    defer testing.allocator.free(written);
    try testing.expectEqualStrings("ab", written);
}

test "the spinner turns with the time a program runs, and hears nothing while none runs" {
    try testing.expectEqualStrings("|", runner.spinner(0));
    try testing.expectEqualStrings("/", runner.spinner(1));
    try testing.expectEqualStrings("-", runner.spinner(2));
    try testing.expectEqualStrings("\\", runner.spinner(3));
    try testing.expectEqualStrings("|", runner.spinner(4));
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    const owner = sequencer.inboxOf(first_owner);
    bench.step();
    try testing.expect(bench.frameTag() == null);

    runner.run(&bench.memory, &bench.tables, .{ .owner = Bench.reply(first_owner), .argv = "sleep\x1f30" });
    bench.step();
    const tag = bench.frameTag() orelse return error.NotSubscribed;
    const turned = runner.phase(&bench.tables);
    const frames = [_]f32{ 0.1, 0.1, 0.05 };
    for (frames) |seconds| {
        const frame_time: time.FrameMsg = .{ .raw_dt = seconds, .dt = seconds, .frame_index = 0 };
        try sequencer.deliverMessage(&bench.tables, sequencer.inboxOf(runner.system()), tag, &.{}, std.mem.asBytes(&frame_time));
    }
    bench.step();
    try testing.expectEqual(turned + 2, runner.phase(&bench.tables));

    runner.giveUp(&bench.memory, &bench.tables, owner);
    bench.step();
    try testing.expect(bench.frameTag() == null);
}
