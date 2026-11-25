//! Tests of vcs-git's system (`git_status.zig`) and its page (`git_status_view.zig`), run alone
//! over its tables: a job it queues is read from the runner's requests, and its answer is given
//! as the runner gives it, a finished job's row with a stand-in program whose kept output is the
//! test's literal, then a `Finished` in the panel's inbox. No program runs, but in the one test
//! that runs the panel with the runner and the process system over a real git repository
//! (skipped on Windows and where `git` is not on `PATH`).

const std = @import("std");
const builtin = @import("builtin");
const mesha = @import("mesha");
const mesha_runtime = @import("mesha_runtime");
const outline = mesha.ui.outline;
const ui = mesha.ui;
const Atom = mesha.Atom;
const Table = mesha.Table;
const memory_mod = mesha.memory;
const plugin = mesha.plugin;
const process = mesha.process;
const sequencer = mesha.sequencer;
const editor = @import("../editor.zig");
const editor_sequencer = @import("../editor_sequencer.zig");
const action_palette = @import("../action_palette.zig");
const open = @import("../open.zig");
const transient = @import("../transient.zig");
const workspaces = @import("../workspaces.zig");
const git = @import("git.zig");
const runner = @import("runner.zig");
const vcs_page = @import("page.zig");
const git_status = @import("git_status.zig");
const git_commit = @import("git_commit.zig");
const view = @import("git_status_view.zig");
const document = @import("../document/document.zig");
const document_sources = @import("../document/sources.zig");
const testing = std.testing;
const SectionKind = git_status.SectionKind;
const text_editor = plugin.text_editor_api;
const editor_text_editor = @import("../text_editor.zig");

/// Where the tests' project is, below its repository's root.
const working_directory = "/work/repo/sub";
const host = "/opt/mesha/mesha";
const home = "/work";

/// The panel's system alone over its tables, with stand-ins for the programs its jobs ran.
pub const Bench = struct {
    memory: memory_mod.Memory = undefined,
    atoms: Atom.Registry = undefined,
    tables: Table.Registry = undefined,
    /// What each stand-in program said, read through its table's address, as the process
    /// system keeps it.
    outputs: [process.max_processes]process.Output = undefined,
    programs: u32 = 0,
    serial: u32 = 0,
    arena: std.heap.ArenaAllocator = undefined,
    /// The project's directory, as `os_places` says it.
    working_directory: []const u8 = working_directory,
    /// The host's path, as `os_places` says it: what git is told its editors are.
    executable: []const u8 = host,
    /// The process system, for the test that runs real programs; null for the others.
    processes: ?*mesha_runtime.process.Processes = null,

    pub fn init(bench: *Bench) !void {
        bench.memory.init(testing.allocator);
        try bench.atoms.init(&bench.memory);
        try bench.tables.init(&bench.memory, 64);
        bench.arena = std.heap.ArenaAllocator.init(testing.allocator);
        const scratch = try bench.memory.tableScratchAllocator();
        try sequencer.ensure(scratch, &bench.atoms, &bench.tables);
        try process.ensureTables(scratch, &bench.atoms, &bench.tables);
        try runner.ensure(scratch, &bench.atoms, &bench.tables);
        try git_status.ensure(scratch, &bench.atoms, &bench.tables);
        try workspaces.ensure(scratch, &bench.atoms, &bench.tables);
        try open.ensure(scratch, &bench.atoms, &bench.tables);
        try mesha.panels.ensure(scratch, &bench.atoms, &bench.tables);
        try plugin.panels.Requests.ensure(scratch, &bench.atoms, &bench.tables, plugin.panels.commands_table_name);
        try text_editor.Requests.ensure(scratch, &bench.atoms, &bench.tables, text_editor.commands_table_name);
        try transient.Requests.ensure(scratch, &bench.atoms, &bench.tables, transient.requests_table_name);
        try action_palette.Requests.ensure(scratch, &bench.atoms, &bench.tables, action_palette.requests_table_name);
        try action_palette.prepareCompletionArenas(&bench.memory, &bench.atoms);
        try bench.ensurePlaces();
        try bench.ensureHost();
        const alone: sequencer.Sequencer = .{ .name = "vcs_git_test", .steps = &.{.{ .system = git_status.system() }} };
        try sequencer.ensureInboxes(scratch, &bench.atoms, &bench.tables, &alone);
        // The page's view, as the panels system would tell its panel's size: no panel is laid
        // out here.
        const page_state = bench.pageState();
        page_state.document_view_width.* = 800;
        page_state.document_view_height.* = 600;
    }

    pub fn deinit(bench: *Bench) void {
        bench.arena.deinit();
        bench.tables.deinit();
        bench.atoms.deinit();
        bench.memory.deinit();
    }

    /// `os_places`, as the host's OS system makes it, the project at `working_directory`.
    pub fn ensurePlaces(bench: *Bench) !void {
        const scratch = try bench.memory.tableScratchAllocator();
        var places: Table.Schema = undefined;
        try places.init(scratch.allocator, &bench.atoms, 4);
        defer places.deinit();
        try places.addFieldFallible("working_directory", Table.String, .text_field);
        try places.addFieldFallible("home_directory", Table.String, .text_field);
        try places.addFieldFallible("executable", Table.String, .text_field);
        try places.addFieldFallible("vendor_directory", Table.String, .text_field);
        try bench.atoms.tryInternAll(&.{mesha.os.places_table_name});
        const no_path: []const u8 = "";
        const no_places = .{ .working_directory = no_path, .home_directory = no_path, .executable = no_path, .vendor_directory = no_path };
        _ = try bench.tables.ensureSingleton(&places, Atom.from(mesha.os.places_table_name), no_places, .durable);
        const found = bench.tables.findByName(Atom.from(mesha.os.places_table_name)).?;
        const row: Table.RowHandle = .{ .row = 0, .generation = found.rowGeneration(0) };
        try found.setString(row, "working_directory", bench.working_directory);
        try found.setString(row, "executable", bench.executable);
        try found.setString(row, "home_directory", home);
    }

    /// What the host keeps that the refresh's triggers read and write: the text editors'
    /// events, the window's size and focus (focused), the time system's requests, and the
    /// editor's settings, none of them set.
    pub fn ensureHost(bench: *Bench) !void {
        const scratch = try bench.memory.tableScratchAllocator();
        try text_editor.Events.ensure(scratch, &bench.atoms, &bench.tables, text_editor.events_table_name);
        try mesha.time.ensureTables(scratch, &bench.atoms, &bench.tables);
        try mesha.keybinds.init(&bench.atoms, &bench.tables);
        try editor_text_editor.ensureSettings(&bench.tables);
        try bench.atoms.tryInternAll(&.{mesha.os.window_table_name});

        var window: Table.Schema = undefined;
        try window.init(scratch.allocator, &bench.atoms, 3);
        defer window.deinit();
        try window.addFieldFallible("width", u32, .int);
        try window.addFieldFallible("height", u32, .int);
        try window.addFieldFallible(mesha.os.window_focused_field, u8, .int);
        _ = try bench.tables.ensureSingleton(&window, Atom.from(mesha.os.window_table_name), .{ .width = @as(u32, 800), .height = @as(u32, 600), .focused = @as(u8, 1) }, .durable);

        // The clock, as much of it as vcs-git reads: the instant on the awake clock.
        var clock: Table.Schema = undefined;
        try clock.init(scratch.allocator, &bench.atoms, 1);
        defer clock.deinit();
        try clock.addFieldFallible("prev_time", std.Io.Timestamp, .hex);
        try bench.atoms.tryInternAll(&.{mesha.time.state_table_name});
        _ = try bench.tables.ensureSingleton(&clock, Atom.from(mesha.time.state_table_name), .{ .prev_time = std.Io.Timestamp{ .nanoseconds = 1000 * std.time.ns_per_s } }, .durable);
    }

    /// The awake clock moved on `seconds`, as the time system reads it on the next frame, the
    /// host asleep or not in between.
    pub fn advanceClock(bench: *Bench, seconds: i64) void {
        const clock = bench.tables.findByName(Atom.from(mesha.time.state_table_name)).?;
        const row = clock.getRow(.{ .row = 0, .generation = clock.rowGeneration(0) }, mesha.time.AwakeView).?;
        row.prev_time.nanoseconds += seconds * std.time.ns_per_s;
    }

    /// What vcs-git asked of the time system since this was last called, the last request:
    /// `null` for none. The requests are taken, as the time system takes them.
    pub fn timerAsked(bench: *Bench) ?TimerAsk {
        const commands = bench.tables.findByName(Atom.from(mesha.time.commands_table_name)).?;
        defer commands.clear();
        var last: ?TimerAsk = null;
        var rows = commands.readQuery(struct { op: *mesha.time.CommandOp, wake: *mesha.time.Wake });
        while (rows.next()) |row| {
            const wake = row.view.wake.*;
            if (wake.inbox != sequencer.inboxOf(git_status.system()) or wake.tag != Atom.from(git_status.Msg.vcs_git_timer)) continue;
            last = switch (row.view.op.*) {
                .wake => .{ .wake = wake.after },
                .cancel_wake => .cancel,
                .animate, .cancel_animation => last,
            };
        }
        return last;
    }

    /// The timer's wake delivered, as the time system delivers it once it falls due, and the
    /// system's run.
    pub fn fireTimer(bench: *Bench) !void {
        const fired: mesha.time.WakeMsg = .{ .after = 5 };
        try sequencer.deliverMessage(&bench.tables, sequencer.inboxOf(git_status.system()), Atom.from(git_status.Msg.vcs_git_timer), &.{}, std.mem.asBytes(&fired));
        bench.run();
    }

    /// Whether the engine's window has the focus.
    pub fn setWindowFocused(bench: *Bench, focused: bool) void {
        const window = bench.tables.findByName(Atom.from(mesha.os.window_table_name)).?;
        const row = window.getRow(.{ .row = 0, .generation = window.rowGeneration(0) }, mesha.os.WindowFocusView).?;
        row.focused.* = @intFromBool(focused);
    }

    /// The setting `vcs_refresh_seconds`, set to `seconds`.
    pub fn setRefreshSeconds(bench: *Bench, seconds: u32) !void {
        const settings = bench.tables.findByName(Atom.from(mesha.keybinds.editor_settings_name)).?;
        var rows = settings.rows();
        const row = rows.next().?;
        try settings.writeFieldSingle(u32, row, mesha.keybinds.vcs_refresh_field, seconds);
    }

    /// The panel's system runs, as in the editor's frame.
    pub fn run(bench: *Bench) void {
        const solo = sequencer.Solo.of("vcs_git_test", git_status.system());
        editor_sequencer.run(&bench.memory, &bench.atoms, &bench.tables, &solo.sequencer(), null);
        bench.tables.reclaimPayloads();
    }

    /// The action `tag` invoked, as the actions host delivers it, and the system's run.
    pub fn act(bench: *Bench, tag: git_status.Msg) !void {
        const inbox = sequencer.inboxOf(git_status.system());
        try sequencer.deliverMessage(&bench.tables, inbox, Atom.from(tag), &.{}, &.{});
        bench.run();
    }

    pub fn requests(bench: *Bench) runner.Requests {
        return runner.Requests.of(&bench.memory, &bench.tables, runner.requests_table_name);
    }

    /// The jobs the panel queued since the requests were last forgotten, in order.
    pub fn queued(bench: *Bench, into: []runner.Job) []runner.Job {
        var sent: [32]runner.Request = undefined;
        var count: usize = 0;
        for (bench.requests().peek(&sent)) |request| switch (request) {
            .run => |job| {
                into[count] = job;
                count += 1;
            },
            .release, .give_up => {},
        };
        return into[0..count];
    }

    /// Whether the panel asked the runner to release the job `serial`.
    pub fn released(bench: *Bench, serial: u32) bool {
        var sent: [32]runner.Request = undefined;
        for (bench.requests().peek(&sent)) |request| switch (request) {
            .release => |job| if (job == serial) return true,
            .run, .give_up => {},
        };
        return false;
    }

    /// Whether the panel gave up its jobs.
    pub fn gaveUp(bench: *Bench) bool {
        var sent: [32]runner.Request = undefined;
        for (bench.requests().peek(&sent)) |request| switch (request) {
            .give_up => |owner| if (owner == sequencer.inboxOf(git_status.system())) return true,
            .run, .release => {},
        };
        return false;
    }

    /// What the panel told the person, in order.
    pub fn told(bench: *Bench, into: [][]const u8) [][]const u8 {
        var sent: [32]text_editor.CmdPayload = undefined;
        var count: usize = 0;
        const commands = text_editor.Requests.of(&bench.memory, &bench.tables, text_editor.commands_table_name);
        for (commands.peek(&sent)) |request| switch (request) {
            .message => |line| {
                into[count] = line;
                count += 1;
            },
            else => {},
        };
        return into[0..count];
    }

    /// Forgets the requests the panel sent the runner, the text editor and the palette.
    pub fn forgetRequests(bench: *Bench) void {
        bench.requests().reset();
        text_editor.Requests.of(&bench.memory, &bench.tables, text_editor.commands_table_name).reset();
        bench.dialogs().reset();
    }

    pub fn dialogs(bench: *Bench) action_palette.Requests {
        return action_palette.Requests.of(&bench.memory, &bench.tables, action_palette.requests_table_name);
    }

    /// The dialog the panel presented since the requests were last forgotten; null for none.
    pub fn dialog(bench: *Bench) ?Presented {
        var sent: [8]action_palette.Request = undefined;
        for (bench.dialogs().peek(&sent)) |request| switch (request) {
            .present => |presented| return .{ .completions = presented.completions, .reply = presented.reply },
            else => {},
        };
        return null;
    }

    pub const Presented = struct { completions: *const action_palette.Completions, reply: sequencer.ReplyTo };

    /// The person chose `label` in `presented`, and the panel's system runs.
    pub fn choose(bench: *Bench, presented: Presented, label: []const u8) !void {
        const chosen = for (presented.completions.entries) |entry| {
            if (std.mem.eql(u8, entry.label, label)) break entry;
        } else return error.NoSuchEntry;
        const payload = try plugin.editor_api.eventPayload(bench.arena.allocator(), .{ .kind = .completed, .completion = chosen, .query = "" });
        const reply = presented.reply;
        try sequencer.deliverMessage(&bench.tables, reply.inbox, reply.tag, reply.user_data.bytes, payload);
        bench.run();
    }

    /// The person closed `presented` choosing nothing, and the panel's system runs.
    pub fn dismiss(bench: *Bench, presented: Presented) !void {
        const payload = try plugin.editor_api.eventPayload(bench.arena.allocator(), .{ .kind = .completed, .completion = null, .query = "" });
        const reply = presented.reply;
        try sequencer.deliverMessage(&bench.tables, reply.inbox, reply.tag, reply.user_data.bytes, payload);
        bench.run();
    }

    /// A click on `spot`, as the page's draw sends it (a heading's or a line's own message, a
    /// row's the grid's), and the system's run: the cursor goes there, or, already there, what
    /// it is on is chosen.
    pub fn click(bench: *Bench, spot: Spot) !void {
        const inbox = sequencer.inboxOf(git_status.system());
        const input = git_status.status_page.input();
        switch (spot) {
            .block => |key| {
                const clicked: document.Click = .{ .document = input.document, .block = key };
                try sequencer.deliverMessage(&bench.tables, inbox, input.tags.click, std.mem.asBytes(&clicked), &.{});
            },
            .row => |row| {
                const chunk = row.position / document.rows_a_chunk;
                const clicked: mesha.ui.grid.CellClick = .{ .instance = document.instanceOf(input.document, row.block, chunk), .row = row.handle.row, .field = 0 };
                try sequencer.deliverMessage(&bench.tables, inbox, Atom.from(mesha.ui.grid.Msg.cell_click), std.mem.asBytes(&clicked), &.{});
            },
        }
        bench.run();
    }

    /// The page's cursor put on `spot`, as the panel's row holds it, outside any run.
    pub fn placeCursor(bench: *Bench, spot: Spot) !void {
        const page = try bench.laidOutPage();
        const cursor: document.Cursor = switch (spot) {
            .block => |key| blk: {
                for (page.blocks) |block| {
                    if (block.key == key) break :blk .{ .block = key, .index = block.first_stop };
                }
                return error.NoSuchBlock;
            },
            .row => |row| document.cursorOnRow(page, row.block, row.handle),
        };
        document.setCursor(bench.pageState(), cursor);
    }

    /// The cursor put on what says `text` under `section`, and `tag` invoked there.
    pub fn actOn(bench: *Bench, section: SectionKind, text: []const u8, tag: git_status.Msg) !void {
        try bench.placeCursor(try bench.spotOf(section, text));
        try bench.act(tag);
    }

    /// What `job` was for.
    pub fn purposeOf(job: runner.Job) git_status.Purpose {
        const data = std.mem.bytesToValue(git_status.JobData, job.owner.user_data.bytes[0..@sizeOf(git_status.JobData)]);
        return @enumFromInt(data.purpose);
    }

    /// The job queued for `purpose` among `jobs`.
    pub fn jobFor(jobs: []const runner.Job, purpose: git_status.Purpose) !runner.Job {
        for (jobs) |job| {
            if (purposeOf(job) == purpose) return job;
        }
        return error.NotQueued;
    }

    /// The job's row as the runner keeps it once its program ended with `code`, having said
    /// `said` and `errors`, and its answer in the panel's inbox. Returns its serial.
    pub fn finish(bench: *Bench, job: runner.Job, code: i32, said: []const u8, errors: []const u8) !u32 {
        bench.serial += 1;
        const serial = bench.serial;
        const slot = bench.programs;
        bench.programs += 1;
        const allocator = bench.arena.allocator();
        var output: process.Output = .{ .streams = .{ .{}, .{} } };
        try output.streams[@intFromEnum(process.Stream.stdout)].bytes.appendSlice(allocator, said);
        try output.streams[@intFromEnum(process.Stream.stderr)].bytes.appendSlice(allocator, errors);
        bench.outputs[slot] = output;
        const program: u32 = slot + 1;
        try bench.addProgram(slot, program, code, said.len, errors.len);
        const jobs = bench.tables.findByName(Atom.from(runner.jobs_table_name)).?;
        _ = try jobs.tryInsert(.{
            .serial = serial,
            .owner = job.owner.inbox,
            .reply_tag = job.owner.tag,
            .reply_user_data = job.owner.user_data.bytes,
            .state = @as(u8, @intFromEnum(runner.JobState.finished)),
            .order = @as(u8, @intFromEnum(job.order)),
            .process = program,
            .argv = job.argv,
            .input = job.input,
            .environment = job.environment,
            .directory = job.directory,
            .shown = job.shown,
        });
        const finished: runner.Finished = .{ .job = serial, .code = code, .started = @intFromEnum(process.SpawnResult.spawned) };
        try sequencer.deliverMessage(&bench.tables, job.owner.inbox, job.owner.tag, job.owner.user_data.bytes, std.mem.asBytes(&finished));
        return serial;
    }

    /// A stand-in program in `slot`, ended with `code`, as the process system keeps one.
    pub fn addProgram(bench: *Bench, slot: u32, program: u32, code: i32, said_bytes: usize, error_bytes: usize) !void {
        const scratch = try bench.memory.tableScratchAllocator();
        var schema: Table.Schema = undefined;
        try schema.init(scratch.allocator, &bench.atoms, 8);
        defer schema.deinit();
        try schema.addFieldFallible("process", u32, .int);
        try schema.addFieldFallible("state", u8, .int);
        try schema.addFieldFallible("exit_code", i32, .int);
        try schema.addFieldFallible("output_address", u64, .int);
        try schema.addFieldFallible("stdout_offset", u64, .int);
        try schema.addFieldFallible("stdout_bytes", u64, .int);
        try schema.addFieldFallible("stderr_offset", u64, .int);
        try schema.addFieldFallible("stderr_bytes", u64, .int);
        const name = process.child_table_atoms[slot];
        const ensured = try bench.tables.ensure(&schema, 1, name, .durable);
        const table = bench.tables.get(ensured.handle).?;
        _ = try table.tryInsert(.{
            .process = program,
            .state = @as(u8, @intFromEnum(process.State.exited)),
            .exit_code = code,
            .output_address = @as(u64, @intFromPtr(&bench.outputs[slot])),
            .stdout_offset = @as(u64, 0),
            .stdout_bytes = @as(u64, said_bytes),
            .stderr_offset = @as(u64, 0),
            .stderr_bytes = @as(u64, error_bytes),
        });
        const children = bench.tables.findByName(Atom.from(process.children_table_name)).?;
        _ = try children.tryInsert(.{ .process = program, .table = name });
    }

    /// `job`'s answer in the panel's inbox with no row of it kept: the runner let it go, as it
    /// does past `max_unreleased`.
    pub fn finishUnkept(bench: *Bench, job: runner.Job) !void {
        bench.serial += 1;
        const finished: runner.Finished = .{ .job = bench.serial, .code = 0, .started = @intFromEnum(process.SpawnResult.spawned) };
        try sequencer.deliverMessage(&bench.tables, job.owner.inbox, job.owner.tag, job.owner.user_data.bytes, std.mem.asBytes(&finished));
    }

    /// A job of the panel's that runs, as the runner keeps it: what `busy` and `running` read.
    pub fn markRunning(bench: *Bench, job: runner.Job) !void {
        bench.serial += 1;
        const jobs = bench.tables.findByName(Atom.from(runner.jobs_table_name)).?;
        _ = try jobs.tryInsert(.{
            .serial = bench.serial,
            .owner = job.owner.inbox,
            .reply_tag = job.owner.tag,
            .reply_user_data = job.owner.user_data.bytes,
            .state = @as(u8, @intFromEnum(runner.JobState.running)),
            .order = @as(u8, @intFromEnum(job.order)),
            .process = @as(u32, 0),
            .argv = job.argv,
            .input = job.input,
            .environment = job.environment,
            .directory = job.directory,
            .shown = job.shown,
        });
    }

    /// The status's page as its draw lays it out now.
    pub fn laidOutPage(bench: *Bench) !document.Layout {
        return vcs_page.laidOutIn(bench.arena.allocator(), &bench.tables, &bench.atoms, git_status.status_page);
    }

    /// The page's cursor, scroll and view, in the panel's row.
    pub fn pageState(bench: *Bench) document.StateRow {
        const state = bench.tables.findByName(Atom.from(git_status.state_table_name)).?;
        return state.getRow(.{ .row = 0, .generation = state.rowGeneration(0) }, document.StateRow).?;
    }

    /// What the page's cursor is on now.
    pub fn at(bench: *Bench) !document.At {
        const page = try bench.laidOutPage();
        return document.at(page, document.cursorOf(bench.pageState()));
    }

    /// The value the panel published as `name`; null for none.
    pub fn value(bench: *Bench, name: []const u8) ?[]const u8 {
        const values = bench.tables.findByName(Atom.from(document_sources.values_table_name)).?;
        return document_sources.valueOf(values.readQuery(document_sources.ValueRow), name);
    }

    /// The row of `section`'s table whose shown path (a commit's short hash) is `text`; null for
    /// none.
    pub fn file(bench: *Bench, section: SectionKind, text: []const u8) ?git_status.FileRow {
        const table = bench.tables.findByName(section.table().?).?;
        var rows = table.readQuery(git_status.FileRow);
        while (rows.next()) |row| {
            if (std.mem.eql(u8, row.view.path, text)) return .{ .change = row.view.change, .path = row.view.path, .git_path = row.view.git_path, .original_path = row.view.original_path, .letters = row.view.letters };
        }
        return null;
    }

    /// Where on the page `text` is said under `section`: a heading that says it, a line of text
    /// (`none`: a term, by its term), or a row of the section's table whose path (a commit's
    /// short hash) it is.
    pub fn spotOf(bench: *Bench, section: SectionKind, text: []const u8) !Spot {
        const page = try bench.laidOutPage();
        for (page.shown) |index| {
            const block = page.blocks[index];
            switch (block.kind) {
                .heading => if (std.mem.eql(u8, block.text, text)) return .{ .block = block.key },
                .paragraph, .term, .text, .unpublished, .group => if (section == .none and std.mem.eql(u8, block.text, text)) return .{ .block = block.key },
                .table => {
                    const table = block.table.?;
                    if (!std.mem.eql(u8, table.source, section.sourceName())) continue;
                    var position: u32 = 0;
                    while (position < table.rows) : (position += 1) {
                        const handle = document.rowAt(table.table, position) orelse continue;
                        const named = if (section == .recent) table.table.getRow(handle, git_status.CommitRow).?.hash else table.table.getRow(handle, git_status.FileRow).?.path;
                        if (std.mem.eql(u8, named, text)) return .{ .row = .{ .block = block.key, .handle = handle, .position = position } };
                    }
                },
            }
        }
        std.debug.print("nothing says \"{s}\" under {t} among:\n", .{ text, section });
        for (page.shown) |index| std.debug.print("  {t} \"{s}\"\n", .{ page.blocks[index].kind, page.blocks[index].text });
        return error.NoSuchSpot;
    }
};

/// A place on the status's page: a heading or a line of text, by its block's key, or a row of a
/// table, by its block's key, its handle and its place in the table.
pub const Spot = union(enum) {
    block: u64,
    row: struct { block: u64, handle: Table.RowHandle, position: u32 },
};

/// What vcs-git asked the time system for its timer: a wake so many seconds on, or none.
pub const TimerAsk = union(enum) { wake: f32, cancel };

/// Whether the page shows a heading that says `text`.
pub fn headingShown(page: document.Layout, text: []const u8) bool {
    for (page.shown) |index| {
        const block = page.blocks[index];
        if (block.kind == .heading and std.mem.eql(u8, block.text, text)) return true;
    }
    return false;
}

/// Whether the page shows a heading that begins `prefix`.
pub fn headingBeginning(page: document.Layout, prefix: []const u8) bool {
    for (page.shown) |index| {
        const block = page.blocks[index];
        if (block.kind == .heading and std.mem.startsWith(u8, block.text, prefix)) return true;
    }
    return false;
}

/// Expects the page to show the heading `text`.
pub fn expectHeading(page: document.Layout, text: []const u8) !void {
    if (headingShown(page, text)) return;
    std.debug.print("no heading \"{s}\" among:\n", .{text});
    for (page.shown) |index| std.debug.print("  {t} \"{s}\"\n", .{ page.blocks[index].kind, page.blocks[index].text });
    return error.NoSuchHeading;
}

/// The person moves the status's cursor onto what says `text` under `section`, as a click moves
/// it, and the system runs.
pub fn moveOnto(bench: *Bench, section: SectionKind, text: []const u8) !void {
    try bench.click(try bench.spotOf(section, text));
}

/// RET on the recent commit whose short hash is `short_hash`.
pub fn visitCommit(bench: *Bench, short_hash: []const u8) !void {
    try bench.actOn(.recent, short_hash, .vcs_git_visit);
}

/// A branch `main` one commit ahead of `origin/main`: `a.txt` changed in the index and again in
/// the working tree, `old.txt` renamed `new.txt` and staged, and `notes.txt` new.
pub const changed_status = "# branch.oid 5fa486e7e3477e590b3d2beb26d6f1e27a0a5b0f\x00# branch.head main\x00# branch.upstream origin/main\x00# branch.ab +1 -0\x00" ++
    "1 MM N... 100644 100644 100644 8c774644110a47745de91a91c7d99b01433a976b ab4d2b1079bf560e64cdb7242e2cdcceca23cf4c a.txt\x00" ++
    "2 R. N... 100644 100644 100644 4cb29ea38f70d7c61b2a3a25b02e3bdf44905402 4cb29ea38f70d7c61b2a3a25b02e3bdf44905402 R100 new.txt\x00old.txt\x00" ++
    "? notes.txt\x00";
pub const recent_commits = "5fa486e7e3477e590b3d2beb26d6f1e27a0a5b0f\x1f5fa486e\x1fAna\x1f2026-11-20\x1fHEAD -> main\x1fTeach the panel its sections\x00" ++
    "72f25b65411d1f8a0a15a3f577334b3e0e3a4cc0\x1f72f25b6\x1fAna\x1f2026-11-19\x1f\x1fStart\x00";

/// The panel opened and its first refresh answered: the repository at `/work/repo`, as
/// `changed_status` and `recent_commits` say, with no operation in progress.
pub fn openAnswered(bench: *Bench) !void {
    try openAnsweredWith(bench, changed_status);
}

/// The panel opened and its first refresh answered with `status`.
pub fn openAnsweredWith(bench: *Bench, status: []const u8) !void {
    try bench.act(.vcs_git_status);
    var storage: [8]runner.Job = undefined;
    const jobs = bench.queued(&storage);
    _ = try bench.finish(try Bench.jobFor(jobs, .status), 0, status, "");
    _ = try bench.finish(try Bench.jobFor(jobs, .recent), 0, recent_commits, "");
    _ = try bench.finish(try Bench.jobFor(jobs, .operation), 0, "", "");
    _ = try bench.finish(try Bench.jobFor(jobs, .root), 0, "/work/repo\n", "");
    bench.run();
    bench.forgetRequests();
}

pub fn expectArgv(job: runner.Job, command: git.Command) !void {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try git.writeArgv(&writer, command);
    try testing.expectEqualStrings(writer.buffered(), job.argv);
}

test "vcs git status: opening vcs-git runs status and recent, and no diff" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try bench.act(.vcs_git_status);
    try testing.expect(workspaces.panelShown(&bench.tables, git_status.panel));

    // The first refresh for a project: status and recent, the operation in progress and the
    // repository's root, run together in the working directory, with git's variables.
    var storage: [8]runner.Job = undefined;
    const jobs = bench.queued(&storage);
    try testing.expectEqual(@as(usize, 4), jobs.len);
    try expectArgv(try Bench.jobFor(jobs, .status), .status);
    try expectArgv(try Bench.jobFor(jobs, .recent), .recent);
    try expectArgv(try Bench.jobFor(jobs, .operation), .operation);
    try expectArgv(try Bench.jobFor(jobs, .root), .root);
    for (jobs) |job| {
        try testing.expect(std.mem.indexOf(u8, job.argv, "\x1fdiff\x1f") == null);
        try testing.expectEqual(runner.Order.shared, job.order);
        try testing.expectEqualStrings(working_directory, job.directory);
        try testing.expectEqualStrings("", job.input);
        try testing.expect(std.mem.startsWith(u8, job.environment, "GIT_TERMINAL_PROMPT=0\x1fGIT_EDITOR=\"" ++ host ++ "\" --stdin-to-file"));
    }

    // Asked again while it runs, the refresh is noted, not run twice; it runs once the first
    // ends: two processes, the root known and nothing in progress.
    var first: [8]runner.Job = undefined;
    @memcpy(first[0..jobs.len], jobs);
    try bench.act(.vcs_git_refresh);
    const after_noted = bench.queued(&storage);
    try testing.expectEqual(@as(usize, 4), after_noted.len);
    _ = try bench.finish(try Bench.jobFor(after_noted, .status), 0, changed_status, "");
    _ = try bench.finish(try Bench.jobFor(after_noted, .recent), 0, recent_commits, "");
    _ = try bench.finish(try Bench.jobFor(after_noted, .operation), 0, "", "");
    _ = try bench.finish(try Bench.jobFor(after_noted, .root), 0, "/work/repo\n", "");
    bench.forgetRequests();
    bench.run();
    const noted = bench.queued(&storage);
    try testing.expectEqual(@as(usize, 2), noted.len);
    try expectArgv(try Bench.jobFor(noted, .status), .status);
    try expectArgv(try Bench.jobFor(noted, .recent), .recent);
}

test "vcs git status: a status answer fills the four sources and the values, and the page shows a heading with its count and a row a file" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try bench.act(.vcs_git_status);
    var storage: [8]runner.Job = undefined;
    const jobs = bench.queued(&storage);
    const status_serial = try bench.finish(try Bench.jobFor(jobs, .status), 0, changed_status, "");
    _ = try bench.finish(try Bench.jobFor(jobs, .recent), 0, recent_commits, "");
    _ = try bench.finish(try Bench.jobFor(jobs, .operation), 0, "", "");
    _ = try bench.finish(try Bench.jobFor(jobs, .root), 0, "/work/repo\n", "");
    bench.run();
    try testing.expect(bench.released(status_serial));

    // The values the page's terms say.
    try testing.expectEqualStrings("main", bench.value("vcs-git.branch").?);
    try testing.expectEqualStrings("Teach the panel its sections", bench.value("vcs-git.head-subject").?);
    try testing.expectEqualStrings("origin/main", bench.value("vcs-git.upstream").?);
    try testing.expectEqualStrings("+1", bench.value("vcs-git.ahead-behind").?);
    try testing.expectEqualStrings("", bench.value("vcs-git.operation").?);
    // Each table a heading with its count; none for the empty unmerged one.
    const page = try bench.laidOutPage();
    try expectHeading(page, "Untracked files (1)");
    try expectHeading(page, "Unstaged changes (1)");
    try expectHeading(page, "Staged changes (2)");
    try expectHeading(page, "Recent commits");
    try testing.expect(!headingBeginning(page, "Unmerged"));
    // A row a file: its change as a word and its path shown, git's path, a rename's original
    // and the letters kept for the commands.
    const notes = bench.file(.untracked, "notes.txt").?;
    try testing.expectEqualStrings("untracked", notes.change);
    const renamed = bench.file(.staged, "old.txt -> new.txt").?;
    try testing.expectEqualStrings("renamed", renamed.change);
    try testing.expectEqualStrings("new.txt", renamed.git_path);
    try testing.expectEqualStrings("old.txt", renamed.original_path);
    try testing.expectEqualStrings("R.", renamed.letters);
    // a.txt is under both its headings, modified in each.
    try testing.expectEqualStrings("modified", bench.file(.unstaged, "a.txt").?.change);
    try testing.expectEqualStrings("modified", bench.file(.staged, "a.txt").?.change);
    try testing.expectEqualStrings("MM", bench.file(.staged, "a.txt").?.letters);
    // The recent commits, newest first, their short hash shown and the full one kept.
    const commits = bench.tables.findByName(Atom.from(git_status.commits_table_name)).?;
    try testing.expectEqual(@as(u32, 2), commits.count());
    var newest = commits.readQuery(git_status.CommitRow);
    const first = newest.next().?.view;
    try testing.expectEqualStrings("5fa486e", first.hash);
    try testing.expectEqualStrings("HEAD -> main", first.refs);
    try testing.expectEqualStrings("Teach the panel its sections", first.subject);
    try testing.expectEqualStrings("5fa486e7e3477e590b3d2beb26d6f1e27a0a5b0f", first.full_hash);
    _ = try bench.spotOf(.recent, "72f25b6");

    // A refresh of a repository on a branch with nothing in progress, its root known, is two
    // processes.
    bench.forgetRequests();
    try bench.act(.vcs_git_refresh);
    const again = bench.queued(&storage);
    try testing.expectEqual(@as(usize, 2), again.len);
    try expectArgv(try Bench.jobFor(again, .status), .status);
    try expectArgv(try Bench.jobFor(again, .recent), .recent);
    // Run in the repository's root, once it is known.
    try testing.expectEqualStrings("/work/repo", again[0].directory);
}

test "vcs git status: a command that fails tells and keeps its output" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try openAnswered(&bench);
    try bench.act(.vcs_git_refresh);
    var storage: [8]runner.Job = undefined;
    const jobs = bench.queued(&storage);
    _ = try bench.finish(try Bench.jobFor(jobs, .status), 0, changed_status, "");
    const failed = try bench.finish(try Bench.jobFor(jobs, .recent), 1, "", "fatal: bad object HEAD\n");
    bench.run();
    try testing.expect(bench.released(failed));

    var said: [8][]const u8 = undefined;
    const lines_told = bench.told(&said);
    try testing.expectEqual(@as(usize, 1), lines_told.len);
    try testing.expectEqualStrings("git log failed; $ shows why", lines_told[0]);
    // The panel keeps what it showed.
    _ = try bench.spotOf(.recent, "5fa486e");
}

test "vcs git status: a directory in no repository is one line, and nothing is told" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try bench.act(.vcs_git_status);
    var storage: [8]runner.Job = undefined;
    const jobs = bench.queued(&storage);
    const not_here = "fatal: not a git repository (or any of the parent directories): .git\n";
    for (jobs) |job| _ = try bench.finish(job, 128, "", not_here);
    bench.run();

    // One line in place of the page: under the home directory, the directory is named from it.
    const state = view.stateOf(&bench.tables).?;
    const notice = (try view.noticeText(bench.arena.allocator(), state)).?;
    try testing.expectEqualStrings("Not a git repository: ~/repo/sub", notice);
    var said: [8][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 0), bench.told(&said).len);

    // `g` asks again: `status` alone, until it answers.
    bench.forgetRequests();
    try bench.act(.vcs_git_refresh);
    const again = bench.queued(&storage);
    try testing.expectEqual(@as(usize, 1), again.len);
    try expectArgv(again[0], .status);
    // Once it is a repository, the rest of the first refresh follows.
    _ = try bench.finish(again[0], 0, changed_status, "");
    bench.forgetRequests();
    bench.run();
    const rest = bench.queued(&storage);
    try testing.expectEqual(@as(usize, 3), rest.len);
    _ = try Bench.jobFor(rest, .recent);
    _ = try Bench.jobFor(rest, .operation);
    _ = try Bench.jobFor(rest, .root);
}

test "vcs git status: the project menu's v shows vcs-git, and in no repository hands over to vcs-p4" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    const scratch = try bench.memory.tableScratchAllocator();
    try plugin.action_api.Requests.ensure(scratch, &bench.atoms, &bench.tables, plugin.action_api.commands_table_name);
    const actions_requests = plugin.action_api.Requests.of(&bench.memory, &bench.tables, plugin.action_api.commands_table_name);
    try bench.act(.vcs_status);
    var storage: [8]runner.Job = undefined;
    const jobs = bench.queued(&storage);
    const not_here = "fatal: not a git repository (or any of the parent directories): .git\n";
    for (jobs) |job| _ = try bench.finish(job, 128, "", not_here);
    bench.run();
    var sent: [8]plugin.action_api.Command = undefined;
    const asked = actions_requests.peek(&sent);
    try testing.expectEqual(@as(usize, 1), asked.len);
    try testing.expectEqual(Atom.from("vcs_p4_status"), asked[0].invoke[1]);
    try testing.expect(!workspaces.panelShown(&bench.tables, git_status.panel));
    // `C-x g` in no repository shows its one line and hands over nothing.
    actions_requests.reset();
    bench.forgetRequests();
    try bench.act(.vcs_git_status);
    for (bench.queued(&storage)) |job| _ = try bench.finish(job, 128, "", not_here);
    bench.run();
    try testing.expectEqual(@as(usize, 0), actions_requests.peek(&sent).len);
    try testing.expect(workspaces.panelShown(&bench.tables, git_status.panel));
}

test "vcs git status: answers whose jobs the runner let go end the refresh" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try bench.act(.vcs_git_status);
    var storage: [8]runner.Job = undefined;
    const jobs = bench.queued(&storage);
    for (jobs) |job| try bench.finishUnkept(job);
    bench.forgetRequests();
    bench.run();
    // The refresh ended: each job is told failed, and `g` runs a new one.
    var said: [8][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 4), bench.told(&said).len);
    bench.forgetRequests();
    try bench.act(.vcs_git_refresh);
    try testing.expectEqual(@as(usize, 4), bench.queued(&storage).len);

    // A refresh that waits on answers that will not come, with nothing running, is forgotten
    // by `C-g`, and `g` runs again.
    bench.forgetRequests();
    try bench.act(.vcs_git_give_up);
    try bench.act(.vcs_git_refresh);
    try testing.expectEqual(@as(usize, 4), bench.queued(&storage).len);
}

/// Whether the page shows a line of text that says `text`.
fn lineShown(page: document.Layout, text: []const u8) bool {
    for (page.shown) |index| {
        const block = page.blocks[index];
        if (block.kind == .paragraph and std.mem.eql(u8, block.text, text)) return true;
    }
    return false;
}

test "vcs git status: files past what the panel keeps are said, not listed" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    const allocator = bench.arena.allocator();
    const extra = 7;
    var status: std.ArrayList(u8) = .empty;
    try status.appendSlice(allocator, "# branch.oid 5fa486e7e3477e590b3d2beb26d6f1e27a0a5b0f\x00# branch.head main\x00");
    for (0..git_status.max_entries + extra) |index| try status.print(allocator, "? build/out{d}.o\x00", .{index});
    try openAnsweredWith(&bench, status.items);
    // The heading says every file the status counted; a line says how many are not listed.
    var heading_buffer: [64]u8 = undefined;
    const heading = try std.fmt.bufPrint(&heading_buffer, "Untracked files ({d})", .{git_status.max_entries + extra});
    const page = try bench.laidOutPage();
    try expectHeading(page, heading);
    try testing.expect(lineShown(page, "7 untracked files are not listed (the panel lists at most 4096 files)"));

    // Staged from the heading, the files listed are staged, and the rest are said to be left.
    try bench.actOn(.untracked, heading, .vcs_git_stage);
    var said: [8][]const u8 = undefined;
    const told = bench.told(&said);
    try testing.expectEqual(@as(usize, 1), told.len);
    try testing.expectEqualStrings("7 more were not listed and were left as they are", told[0]);
    var storage: [8]runner.Job = undefined;
    try testing.expectEqual(@as(usize, 1), bench.queued(&storage).len);
}

test "vcs git status: a section the panel has no room for is said, though its heading is not shown" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    const allocator = bench.arena.allocator();
    // As many tracked changes as the panel keeps, then 5 untracked files, which git lists last.
    var status: std.ArrayList(u8) = .empty;
    try status.appendSlice(allocator, "# branch.oid 5fa486e7e3477e590b3d2beb26d6f1e27a0a5b0f\x00# branch.head main\x00");
    for (0..git_status.max_entries) |index| try status.print(allocator, "1 .M N... 100644 100644 100644 8c774644110a47745de91a91c7d99b01433a976b 8c774644110a47745de91a91c7d99b01433a976b src/f{d}.c\x00", .{index});
    for (0..5) |index| try status.print(allocator, "? new{d}.txt\x00", .{index});
    try openAnsweredWith(&bench, status.items);
    const page = try bench.laidOutPage();
    try testing.expect(!headingBeginning(page, "Untracked"));
    try expectHeading(page, "Unstaged changes (4096)");
    try testing.expect(lineShown(page, "5 untracked files are not listed (the panel lists at most 4096 files)"));
}

test "vcs git status: the stashes and a clean tree are said, each only when there is something to say" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    const clean = "# branch.oid 5fa486e7e3477e590b3d2beb26d6f1e27a0a5b0f\x00# branch.head main\x00# stash 2\x00";
    try openAnsweredWith(&bench, clean);
    try testing.expectEqualStrings("2", bench.value("vcs-git.stashes").?);
    const page = try bench.laidOutPage();
    try testing.expect(lineShown(page, "Nothing to commit, working tree clean"));
    var stashes_shown = false;
    for (page.shown) |index| {
        if (page.blocks[index].kind == .term and std.mem.eql(u8, page.blocks[index].text, "Stashes")) stashes_shown = true;
    }
    try testing.expect(stashes_shown);

    // With changes and no stash: neither line.
    var changed: Bench = .{};
    try changed.init();
    defer changed.deinit();
    try openAnswered(&changed);
    const changed_page = try changed.laidOutPage();
    try testing.expect(!lineShown(changed_page, "Nothing to commit, working tree clean"));
    for (changed_page.shown) |index| try testing.expect(!std.mem.eql(u8, changed_page.blocks[index].text, "Stashes"));
}

test "vcs git status: an answer of an earlier generation is released and dropped" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try bench.act(.vcs_git_status);
    var storage: [8]runner.Job = undefined;
    const jobs = bench.queued(&storage);
    const status_job = try Bench.jobFor(jobs, .status);
    try bench.markRunning(status_job);
    try bench.act(.vcs_git_give_up);
    bench.forgetRequests();

    // The status given up answers anyway: its answer is let go and changes nothing.
    const late = try bench.finish(status_job, 0, changed_status, "");
    bench.run();
    try testing.expect(bench.released(late));
    try testing.expectEqual(@as(u8, 0), view.stateOf(&bench.tables).?.answered.*);
    const untracked = bench.tables.findByName(Atom.from(git_status.untracked_table_name)).?;
    try testing.expectEqual(@as(u32, 0), untracked.count());
}

test "vcs git status: C-g gives up what runs and tells it" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    // With nothing running, C-g gives up nothing and tells nothing.
    try bench.act(.vcs_git_give_up);
    try testing.expect(!bench.gaveUp());
    var said: [8][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 0), bench.told(&said).len);

    try bench.act(.vcs_git_status);
    var storage: [8]runner.Job = undefined;
    const jobs = bench.queued(&storage);
    try bench.markRunning(try Bench.jobFor(jobs, .status));
    bench.forgetRequests();
    try bench.act(.vcs_git_give_up);
    try testing.expect(bench.gaveUp());
    const lines_told = bench.told(&said);
    try testing.expectEqual(@as(usize, 1), lines_told.len);
    try testing.expectEqualStrings("Gave up: git status", lines_told[0]);
}

// ---- diffs and staging -------------------------------------------------------------------------

/// `a.txt` and `b.txt` changed in the working tree, `c.txt` deleted from it.
pub const unstaged_status = "# branch.oid 5fa486e7e3477e590b3d2beb26d6f1e27a0a5b0f\x00# branch.head main\x00" ++
    "1 .M N... 100644 100644 100644 8c774644110a47745de91a91c7d99b01433a976b 8c774644110a47745de91a91c7d99b01433a976b a.txt\x00" ++
    "1 .M N... 100644 100644 100644 8c774644110a47745de91a91c7d99b01433a976b 8c774644110a47745de91a91c7d99b01433a976b b.txt\x00" ++
    "1 .D N... 100644 100644 000000 8c774644110a47745de91a91c7d99b01433a976b 8c774644110a47745de91a91c7d99b01433a976b c.txt\x00";

/// The unstaged diff of `a.txt` under `changed_status`: two hunks, the second ending with no line
/// break at the end of the file.
pub const a_header = "diff --git a/a.txt b/a.txt\nindex 8c77464..ab4d2b1 100644\n--- a/a.txt\n+++ b/a.txt\n";
pub const a_first_hunk = "@@ -1,4 +1,4 @@\n one\n-two\n+TWO\n three\n four\n";
pub const a_second_hunk_header = "@@ -10,3 +10,4 @@ ten\n";
pub const a_second_hunk_body = " eleven\n twelve\n thirteen\n+fourteen\n\\ No newline at end of file\n";
pub const a_diff = a_header ++ a_first_hunk ++ a_second_hunk_header ++ a_second_hunk_body;
/// `b.txt`'s, one hunk.
pub const b_diff = "diff --git a/b.txt b/b.txt\nindex 1111111..2222222 100644\n--- a/b.txt\n+++ b/b.txt\n@@ -3 +3 @@\n-bee\n+BEE\n";

/// The staged diff under `changed_status`: `a.txt`'s one hunk, and the rename as a deleted file
/// and an added one, the diff detecting no renames.
pub const staged_a_hunk = "@@ -1,2 +1,2 @@\n-one\n+One\n two\n";
pub const staged_diff = a_header ++ staged_a_hunk ++
    "diff --git a/new.txt b/new.txt\nnew file mode 100644\nindex 0000000..4cb29ea\n--- /dev/null\n+++ b/new.txt\n@@ -0,0 +1 @@\n+moved\n" ++
    "diff --git a/old.txt b/old.txt\ndeleted file mode 100644\nindex 4cb29ea..0000000\n--- a/old.txt\n+++ /dev/null\n@@ -1 +0,0 @@\n-moved\n";

/// The job queued for the diff of `side` among `jobs`.
pub fn diffJob(jobs: []const runner.Job, side: git.Side) !runner.Job {
    const purpose: git_status.Purpose = switch (side) {
        .unstaged => .unstaged_diff,
        .staged => .staged_diff,
    };
    return Bench.jobFor(jobs, purpose);
}

/// `job`, a command, ends well, and the refresh that follows answers with `status`.
pub fn endCommand(bench: *Bench, job: runner.Job, status: []const u8) !void {
    bench.forgetRequests();
    _ = try bench.finish(job, 0, "", "");
    bench.run();
    var storage: [8]runner.Job = undefined;
    const refresh = bench.queued(&storage);
    var refresh_jobs: [2]runner.Job = undefined;
    @memcpy(&refresh_jobs, refresh);
    bench.forgetRequests();
    _ = try bench.finish(try Bench.jobFor(&refresh_jobs, .status), 0, status, "");
    _ = try bench.finish(try Bench.jobFor(&refresh_jobs, .recent), 0, recent_commits, "");
    bench.run();
}

/// Expects one job queued, alone, a command of the panel's, running `command` with `input`.
pub fn expectCommand(bench: *Bench, command: git.Command, input: []const u8) !runner.Job {
    var storage: [8]runner.Job = undefined;
    const jobs = bench.queued(&storage);
    try testing.expectEqual(@as(usize, 1), jobs.len);
    const job = jobs[0];
    try expectArgv(job, command);
    try testing.expectEqualStrings(input, job.input);
    try testing.expectEqual(runner.Order.alone, job.order);
    try testing.expectEqual(git_status.Purpose.command, Bench.purposeOf(job));
    try testing.expectEqualStrings("/work/repo", job.directory);
    return job;
}

test "vcs git status: s on the unstaged heading stages every file in one program" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try openAnsweredWith(&bench, unstaged_status);
    try bench.actOn(.unstaged, "Unstaged changes (3)", .vcs_git_stage);
    const job = try expectCommand(&bench, .stage, "a.txt\x00b.txt\x00c.txt\x00");
    try testing.expectEqualStrings("git add", job.shown);

    // Its end refreshes: two processes, the root known and nothing in progress.
    bench.forgetRequests();
    _ = try bench.finish(job, 0, "", "");
    bench.run();
    var storage: [8]runner.Job = undefined;
    const refresh = bench.queued(&storage);
    try testing.expectEqual(@as(usize, 2), refresh.len);
    _ = try Bench.jobFor(refresh, .status);
    _ = try Bench.jobFor(refresh, .recent);
    var said: [8][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 0), bench.told(&said).len);

    // `S` stages every unstaged tracked file too, and with two keys queued the refresh waits for both.
    _ = try bench.finish(refresh[0], 0, unstaged_status, "");
    _ = try bench.finish(refresh[1], 0, recent_commits, "");
    bench.run();
    bench.forgetRequests();
    try bench.act(.vcs_git_stage_all);
    try bench.act(.vcs_git_stage_all);
    const both = bench.queued(&storage);
    try testing.expectEqual(@as(usize, 2), both.len);
    for (both) |queued_job| {
        try expectArgv(queued_job, .stage);
        try testing.expectEqualStrings("a.txt\x00b.txt\x00c.txt\x00", queued_job.input);
    }
    var first: [2]runner.Job = undefined;
    @memcpy(&first, both);
    bench.forgetRequests();
    _ = try bench.finish(first[0], 0, "", "");
    bench.run();
    try testing.expectEqual(@as(usize, 0), bench.queued(&storage).len);
    _ = try bench.finish(first[1], 0, "", "");
    bench.run();
    try testing.expectEqual(@as(usize, 2), bench.queued(&storage).len);
}

test "vcs git status: u on a renamed entry passes both paths" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try openAnswered(&bench);
    try bench.actOn(.staged, "old.txt -> new.txt", .vcs_git_unstage);
    const unstage = try expectCommand(&bench, .unstage, "new.txt\x00old.txt\x00");
    try endCommand(&bench, unstage, changed_status);
    bench.forgetRequests();

    // `U` unstages every staged file, the rename with both its paths, in one program.
    try bench.act(.vcs_git_unstage_all);
    _ = try expectCommand(&bench, .unstage, "a.txt\x00new.txt\x00old.txt\x00");
}

test "vcs git status: k asks first and acts on the answer" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try openAnsweredWith(&bench, unstaged_status);
    var storage: [8]runner.Job = undefined;

    try bench.actOn(.unstaged, "b.txt", .vcs_git_discard);
    try testing.expectEqual(@as(usize, 0), bench.queued(&storage).len);
    const asked = bench.dialog() orelse return error.NoDialog;
    try testing.expectEqual(action_palette.Completions.Presentation.dialog, asked.completions.presentation);
    try testing.expectEqualStrings("Discard changes?", asked.completions.title);
    try testing.expectEqualStrings("b.txt", asked.completions.body);
    try testing.expectEqual(@as(?u32, 1), asked.completions.default_entry);
    try testing.expectEqualStrings("Discard", asked.completions.entries[0].label);
    try testing.expectEqualStrings("Cancel", asked.completions.entries[1].label);

    // Cancel runs nothing; Discard throws the file's changes away.
    try bench.choose(asked, "Cancel");
    try testing.expectEqual(@as(usize, 0), bench.queued(&storage).len);
    try bench.choose(asked, "Discard");
    const discard = try expectCommand(&bench, .discard, "b.txt\x00");
    try endCommand(&bench, discard, unstaged_status);

    // Asked, then gone from the status before the answer: nothing runs, and that is told.
    bench.forgetRequests();
    try bench.actOn(.unstaged, "c.txt", .vcs_git_discard);
    const gone = bench.dialog() orelse return error.NoDialog;
    try bench.act(.vcs_git_refresh);
    const refresh = bench.queued(&storage);
    var refresh_jobs: [2]runner.Job = undefined;
    @memcpy(&refresh_jobs, refresh);
    const without_c = changed_status;
    _ = try bench.finish(try Bench.jobFor(&refresh_jobs, .status), 0, without_c, "");
    _ = try bench.finish(try Bench.jobFor(&refresh_jobs, .recent), 0, recent_commits, "");
    bench.run();
    bench.forgetRequests();
    try bench.choose(gone, "Discard");
    try testing.expectEqual(@as(usize, 0), bench.queued(&storage).len);
    var said: [8][]const u8 = undefined;
    const lines_told = bench.told(&said);
    try testing.expectEqual(@as(usize, 1), lines_told.len);
    try testing.expectEqualStrings("It is no longer there", lines_told[0]);

    // An untracked file is deleted with `clean`, after its own question.
    bench.forgetRequests();
    try bench.actOn(.untracked, "notes.txt", .vcs_git_discard);
    const delete = bench.dialog() orelse return error.NoDialog;
    try testing.expectEqualStrings("Delete file?", delete.completions.title);
    try bench.choose(delete, "Delete");
    const clean = bench.queued(&storage);
    try testing.expectEqual(@as(usize, 1), clean.len);
    var clean_buffer: [256]u8 = undefined;
    var clean_argv = std.Io.Writer.fixed(&clean_buffer);
    const paths = [_][]const u8{"notes.txt"};
    try testing.expectEqual(@as(usize, 1), try git.writeClean(&clean_argv, &paths));
    try testing.expectEqualStrings(clean_argv.buffered(), clean[0].argv);
    try testing.expectEqualStrings("", clean[0].input);
    try testing.expectEqual(runner.Order.alone, clean[0].order);
}

test "vcs git status: a key that does not apply tells and runs nothing" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try openAnswered(&bench);
    const cases = [_]struct { section: SectionKind, text: []const u8, tag: git_status.Msg, said: []const u8 }{
        .{ .section = .staged, .text = "a.txt", .tag = .vcs_git_stage, .said = "Already staged" },
        .{ .section = .unstaged, .text = "a.txt", .tag = .vcs_git_unstage, .said = "Not staged" },
        .{ .section = .untracked, .text = "notes.txt", .tag = .vcs_git_unstage, .said = "Not staged" },
        .{ .section = .none, .text = "Head", .tag = .vcs_git_stage, .said = "Nothing to stage here" },
        .{ .section = .recent, .text = "72f25b6", .tag = .vcs_git_unstage, .said = "Nothing to unstage here" },
        .{ .section = .none, .text = "Recent commits", .tag = .vcs_git_stage, .said = "Nothing to stage here" },
        .{ .section = .staged, .text = "a.txt", .tag = .vcs_git_discard, .said = "Unstage it first" },
    };
    var storage: [8]runner.Job = undefined;
    var said: [8][]const u8 = undefined;
    for (cases) |case| {
        bench.forgetRequests();
        try bench.actOn(case.section, case.text, case.tag);
        try testing.expectEqual(@as(usize, 0), bench.queued(&storage).len);
        try testing.expect(bench.dialog() == null);
        const lines_told = bench.told(&said);
        try testing.expectEqual(@as(usize, 1), lines_told.len);
        try testing.expectEqualStrings(case.said, lines_told[0]);
    }
}

test "vcs git status: a staging command that fails tells and still refreshes" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try openAnswered(&bench);
    try bench.actOn(.untracked, "notes.txt", .vcs_git_stage);
    const job = try expectCommand(&bench, .stage, "notes.txt\x00");
    bench.forgetRequests();
    _ = try bench.finish(job, 1, "", "fatal: Unable to create '.git/index.lock': File exists.\n");
    bench.run();
    var said: [8][]const u8 = undefined;
    const lines_told = bench.told(&said);
    try testing.expectEqual(@as(usize, 1), lines_told.len);
    try testing.expectEqualStrings("git add failed; $ shows why", lines_told[0]);
    var storage: [8]runner.Job = undefined;
    const refresh = bench.queued(&storage);
    try testing.expectEqual(@as(usize, 2), refresh.len);
    _ = try Bench.jobFor(refresh, .status);
    _ = try Bench.jobFor(refresh, .recent);
}

test "vcs git status: an empty staged source shows no Staged heading, and every source is published" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try openAnsweredWith(&bench, unstaged_status);
    const page = try bench.laidOutPage();
    try expectHeading(page, "Unstaged changes (3)");
    try testing.expect(!headingBeginning(page, "Staged"));
    try testing.expect(!headingBeginning(page, "Unmerged"));
    try testing.expect(!headingBeginning(page, "Untracked"));
    // Published though empty: no table says it is not.
    const published = bench.tables.findByName(Atom.from(document_sources.sources_table_name)).?;
    const names = [_][]const u8{ "vcs-git.untracked", "vcs-git.unmerged", "vcs-git.unstaged", "vcs-git.staged", "vcs-git.commits" };
    for (names) |name| try testing.expect(document_sources.sourceOf(published.readQuery(document_sources.SourceRow), name) != null);
    for (page.blocks) |block| try testing.expect(block.kind != .unpublished);
    // No upstream: its line is left out.
    try testing.expectEqualStrings("", bench.value("vcs-git.upstream").?);
    for (page.shown) |index| try testing.expect(!std.mem.eql(u8, page.blocks[index].text, "Upstream"));
}

test "vcs git status: s on an unstaged row stages that path" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try openAnsweredWith(&bench, unstaged_status);
    try bench.actOn(.unstaged, "b.txt", .vcs_git_stage);
    const job = try expectCommand(&bench, .stage, "b.txt\x00");
    try testing.expectEqualStrings("git add", job.shown);
}

test "vcs git status: RET on a file's row shows it in the diff panel, on a commit's row that commit" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try openAnswered(&bench);
    var storage: [8]runner.Job = undefined;
    try bench.actOn(.staged, "a.txt", .vcs_git_visit);
    const diff = bench.queued(&storage);
    try testing.expectEqual(@as(usize, 1), diff.len);
    try expectArgv(diff[0], .{ .diff = .staged });
    try testing.expect(workspaces.panelShown(&bench.tables, @import("git_diff.zig").panel));
    bench.forgetRequests();
    try bench.actOn(.recent, "72f25b6", .vcs_git_visit);
    const show = bench.queued(&storage);
    try testing.expectEqual(@as(usize, 1), show.len);
    try expectArgv(show[0], .{ .show = "72f25b65411d1f8a0a15a3f577334b3e0e3a4cc0" });
}

test "vcs git status: a refresh keeps the cursor on the same file's row when it is still there" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try openAnsweredWith(&bench, unstaged_status);
    try bench.placeCursor(try bench.spotOf(.unstaged, "b.txt"));
    // a.txt is staged elsewhere: b.txt moves up a row, its row now another's.
    const without_a = "# branch.oid 5fa486e7e3477e590b3d2beb26d6f1e27a0a5b0f\x00# branch.head main\x00" ++
        "1 M. N... 100644 100644 100644 8c774644110a47745de91a91c7d99b01433a976b 8c774644110a47745de91a91c7d99b01433a976b a.txt\x00" ++
        "1 .M N... 100644 100644 100644 8c774644110a47745de91a91c7d99b01433a976b 8c774644110a47745de91a91c7d99b01433a976b b.txt\x00" ++
        "1 .D N... 100644 100644 000000 8c774644110a47745de91a91c7d99b01433a976b 8c774644110a47745de91a91c7d99b01433a976b c.txt\x00";
    const scroll_before = bench.pageState().document_scroll.*;
    try bench.act(.vcs_git_refresh);
    var storage: [8]runner.Job = undefined;
    const jobs = bench.queued(&storage);
    _ = try bench.finish(try Bench.jobFor(jobs, .status), 0, without_a, "");
    _ = try bench.finish(try Bench.jobFor(jobs, .recent), 0, recent_commits, "");
    bench.run();
    const at = try bench.at();
    try testing.expectEqualStrings("vcs-git.unstaged", at.row.source);
    try testing.expectEqualStrings("b.txt", at.row.table.getRow(at.row.row, git_status.FileRow).?.git_path);
    try testing.expectEqual(@as(?u32, 0), document.positionOf(at.row.table, at.row.row));
    try testing.expectEqual(scroll_before, bench.pageState().document_scroll.*);

    // Gone from its table, the cursor keeps its place: the row that took b.txt's.
    const without_b = "# branch.oid 5fa486e7e3477e590b3d2beb26d6f1e27a0a5b0f\x00# branch.head main\x00" ++
        "1 M. N... 100644 100644 100644 8c774644110a47745de91a91c7d99b01433a976b 8c774644110a47745de91a91c7d99b01433a976b a.txt\x00" ++
        "1 M. N... 100644 100644 100644 8c774644110a47745de91a91c7d99b01433a976b 8c774644110a47745de91a91c7d99b01433a976b b.txt\x00" ++
        "1 .D N... 100644 100644 000000 8c774644110a47745de91a91c7d99b01433a976b 8c774644110a47745de91a91c7d99b01433a976b c.txt\x00";
    bench.forgetRequests();
    try bench.act(.vcs_git_refresh);
    const again = bench.queued(&storage);
    _ = try bench.finish(try Bench.jobFor(again, .status), 0, without_b, "");
    _ = try bench.finish(try Bench.jobFor(again, .recent), 0, recent_commits, "");
    bench.run();
    const settled = try bench.at();
    try testing.expectEqualStrings("c.txt", settled.row.table.getRow(settled.row.row, git_status.FileRow).?.git_path);
}

test "vcs git status: a key in the run whose refresh took the row under the cursor away acts on nothing" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try openAnsweredWith(&bench, unstaged_status);
    try bench.placeCursor(try bench.spotOf(.unstaged, "a.txt"));
    try bench.act(.vcs_git_refresh);
    var storage: [8]runner.Job = undefined;
    const jobs = bench.queued(&storage);
    var refresh: [2]runner.Job = undefined;
    @memcpy(&refresh, jobs);
    bench.forgetRequests();
    // In one run: the answer that takes a.txt away, its row now b.txt's, then `s`.
    const without_a = "# branch.oid 5fa486e7e3477e590b3d2beb26d6f1e27a0a5b0f\x00# branch.head main\x00" ++
        "1 .M N... 100644 100644 100644 8c774644110a47745de91a91c7d99b01433a976b 8c774644110a47745de91a91c7d99b01433a976b b.txt\x00" ++
        "1 .D N... 100644 100644 000000 8c774644110a47745de91a91c7d99b01433a976b 8c774644110a47745de91a91c7d99b01433a976b c.txt\x00";
    _ = try bench.finish(try Bench.jobFor(&refresh, .status), 0, without_a, "");
    _ = try bench.finish(try Bench.jobFor(&refresh, .recent), 0, recent_commits, "");
    try sequencer.deliverMessage(&bench.tables, sequencer.inboxOf(git_status.system()), Atom.from(git_status.Msg.vcs_git_stage), &.{}, &.{});
    bench.run();
    try expectNothingQueued(&bench);
    var said: [8][]const u8 = undefined;
    const told = bench.told(&said);
    try testing.expectEqual(@as(usize, 1), told.len);
    try testing.expectEqualStrings("The status changed under the cursor", told[0]);
    // In the next run the row is the one shown, and `s` stages it.
    bench.forgetRequests();
    try bench.act(.vcs_git_stage);
    _ = try expectCommand(&bench, .stage, "b.txt\x00");
}

test "vcs git status: the diff panel follows a person's move, never a refresh that settled the cursor in the same frame" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try openAnsweredWith(&bench, unstaged_status);
    try bench.actOn(.unstaged, "a.txt", .vcs_git_visit);
    var storage: [8]runner.Job = undefined;
    _ = try bench.finish(try diffJob(bench.queued(&storage), .unstaged), 0, a_diff ++ b_diff, "");
    bench.run();
    bench.forgetRequests();
    // In one frame: a refresh's answer that takes a.txt out of the table, its row now b.txt's,
    // and a turn of the wheel that moves nothing.
    try bench.act(.vcs_git_refresh);
    const jobs = bench.queued(&storage);
    const without_a = "# branch.oid 5fa486e7e3477e590b3d2beb26d6f1e27a0a5b0f\x00# branch.head main\x00" ++
        "1 .M N... 100644 100644 100644 8c774644110a47745de91a91c7d99b01433a976b 8c774644110a47745de91a91c7d99b01433a976b b.txt\x00" ++
        "1 .D N... 100644 100644 000000 8c774644110a47745de91a91c7d99b01433a976b 8c774644110a47745de91a91c7d99b01433a976b c.txt\x00";
    _ = try bench.finish(try Bench.jobFor(jobs, .status), 0, without_a, "");
    _ = try bench.finish(try Bench.jobFor(jobs, .recent), 0, recent_commits, "");
    const input = git_status.status_page.input();
    const wheeled: document.Click = .{ .document = input.document };
    const still: mesha.input.MouseScrollMsg = std.mem.zeroes(mesha.input.MouseScrollMsg);
    try sequencer.deliverMessage(&bench.tables, sequencer.inboxOf(git_status.system()), input.tags.wheel, std.mem.asBytes(&wheeled), std.mem.asBytes(&still));
    bench.run();
    try testing.expectEqualStrings("b.txt", (try bench.at()).row.table.getRow((try bench.at()).row.row, git_status.FileRow).?.git_path);
    try testing.expectEqualStrings("a.txt", @import("git_diff.zig").sourcesOf(&bench.tables).?.row.path);

    // The person's move onto c.txt: the panel follows.
    bench.forgetRequests();
    try bench.act(.vcs_git_next);
    try testing.expectEqualStrings("c.txt", @import("git_diff.zig").sourcesOf(&bench.tables).?.row.path);
}

// ---- refreshing in the background -------------------------------------------------------------

/// The text editors tell of a change of `buffer`, `saved` saying whether it was written to its
/// file, and the system runs.
fn tellChanged(bench: *Bench, saved: bool) void {
    const events = text_editor.Events.of(&bench.tables, text_editor.events_table_name);
    events.publish(.{ .changed = .{ .buffer = Atom.from("vcs_git_test_buffer"), .revision = 1, .serial = 1, .modified = false, .saved = saved } });
    bench.run();
}

/// Expects the jobs queued since the requests were last forgotten to be one refresh, the root
/// known: `status` and `recent`.
fn expectRefresh(bench: *Bench) ![2]runner.Job {
    var storage: [8]runner.Job = undefined;
    const jobs = bench.queued(&storage);
    try testing.expectEqual(@as(usize, 2), jobs.len);
    return .{ try Bench.jobFor(jobs, .status), try Bench.jobFor(jobs, .recent) };
}

fn expectNothingQueued(bench: *Bench) !void {
    var storage: [8]runner.Job = undefined;
    try testing.expectEqual(@as(usize, 0), bench.queued(&storage).len);
}

/// A refresh's two jobs answered with `status` and the recent commits, and the system's run:
/// the requests are forgotten first, so those after are what the answers asked.
fn answerRefresh(bench: *Bench, jobs: [2]runner.Job, status: []const u8) !void {
    bench.forgetRequests();
    _ = try bench.finish(jobs[0], 0, status, "");
    _ = try bench.finish(jobs[1], 0, recent_commits, "");
    bench.run();
}

test "vcs git status: a saved buffer asks a refresh, a change that saved nothing does not" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try openAnswered(&bench);
    tellChanged(&bench, false);
    try expectNothingQueued(&bench);
    tellChanged(&bench, true);
    const jobs = try expectRefresh(&bench);
    // Saved again while it runs: one more once it ends, not two at once.
    bench.forgetRequests();
    tellChanged(&bench, true);
    try expectNothingQueued(&bench);
    try answerRefresh(&bench, jobs, changed_status);
    _ = try expectRefresh(&bench);

    // The panel closed: a save asks nothing.
    var closed: Bench = .{};
    try closed.init();
    defer closed.deinit();
    try openAnswered(&closed);
    try closed.act(.vcs_git_quit);
    closed.forgetRequests();
    tellChanged(&closed, true);
    try expectNothingQueued(&closed);
}

test "vcs git status: the timer asks one refresh after the interval while shown and focused, none while the window is not focused or the panel is hidden, none with the setting at 0" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try openAnswered(&bench);
    // A wake of the time system's, the page's #+REFRESH: 5 seconds on; nothing heard each frame.
    try testing.expectEqual(TimerAsk{ .wake = 5 }, bench.timerAsked().?);
    const subscriptions = bench.tables.findByName(Atom.from(mesha.time.subscriptions_table_name)).?;
    try testing.expectEqual(@as(u32, 0), subscriptions.count());
    bench.run();
    try testing.expect(bench.timerAsked() == null);
    // Its wake: a refresh, which asks the wake again, counting from it.
    try bench.fireTimer();
    const first = try expectRefresh(&bench);
    try testing.expectEqual(TimerAsk{ .wake = 5 }, bench.timerAsked().?);
    // Woken while it runs: none more, the wake asked again.
    bench.forgetRequests();
    try bench.fireTimer();
    try expectNothingQueued(&bench);
    try testing.expectEqual(TimerAsk{ .wake = 5 }, bench.timerAsked().?);
    try answerRefresh(&bench, first, changed_status);

    // The window without the focus: the wake taken back, and a late one does nothing.
    bench.setWindowFocused(false);
    bench.run();
    try testing.expectEqual(TimerAsk.cancel, bench.timerAsked().?);
    bench.forgetRequests();
    try bench.fireTimer();
    try expectNothingQueued(&bench);
    // Focused again, a wake from then.
    bench.setWindowFocused(true);
    bench.run();
    try testing.expectEqual(TimerAsk{ .wake = 5 }, bench.timerAsked().?);
    try bench.fireTimer();
    try answerRefresh(&bench, try expectRefresh(&bench), changed_status);
    _ = bench.timerAsked();

    // The setting at 0: no wake; at 2 seconds, a wake 2 seconds on.
    try bench.setRefreshSeconds(0);
    bench.run();
    try testing.expectEqual(TimerAsk.cancel, bench.timerAsked().?);
    try bench.setRefreshSeconds(2);
    bench.run();
    try testing.expectEqual(TimerAsk{ .wake = 2 }, bench.timerAsked().?);
    try bench.fireTimer();
    try answerRefresh(&bench, try expectRefresh(&bench), changed_status);

    // The panel hidden: the wake taken back, and nothing.
    try bench.act(.vcs_git_quit);
    try testing.expectEqual(TimerAsk.cancel, bench.timerAsked().?);
    bench.forgetRequests();
    try bench.fireTimer();
    try expectNothingQueued(&bench);
}

test "vcs git status: a timer wake not heard within twice its interval is asked again" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try openAnswered(&bench);
    try testing.expectEqual(TimerAsk{ .wake = 5 }, bench.timerAsked().?);
    // Within twice the interval nothing is asked: the wake may still come.
    bench.advanceClock(9);
    bench.run();
    try testing.expect(bench.timerAsked() == null);
    // The host asleep, no frame run, past twice the interval on the awake clock: the wake was
    // rejected (the time system logs that and answers nothing), so the next run asks again,
    // once, and refreshes nothing.
    bench.advanceClock(60);
    bench.run();
    try testing.expectEqual(TimerAsk{ .wake = 5 }, bench.timerAsked().?);
    try expectNothingQueued(&bench);
    bench.run();
    bench.run();
    try testing.expect(bench.timerAsked() == null);
    try expectNothingQueued(&bench);
    // Counting from the new ask.
    bench.advanceClock(9);
    bench.run();
    try testing.expect(bench.timerAsked() == null);
}

test "vcs git status: a timer refresh that changes nothing writes no row and keeps the diff panel as it is" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try openAnsweredWith(&bench, unstaged_status);
    try bench.actOn(.unstaged, "b.txt", .vcs_git_visit);
    var storage: [8]runner.Job = undefined;
    _ = try bench.finish(try diffJob(bench.queued(&storage), .unstaged), 0, a_diff ++ b_diff, "");
    bench.run();
    bench.forgetRequests();
    const cursor_before = document.cursorOf(bench.pageState());
    const unstaged = bench.tables.findByName(Atom.from(git_status.unstaged_table_name)).?;
    const commits = bench.tables.findByName(Atom.from(git_status.commits_table_name)).?;
    const unstaged_revision = unstaged.revision;
    const commits_revision = commits.revision;

    try bench.fireTimer();
    try answerRefresh(&bench, try expectRefresh(&bench), unstaged_status);
    // No diff asked again, the diff panel's bytes held, the cursor where it was, no row
    // written.
    try expectNothingQueued(&bench);
    const loaded = @import("git_diff.zig").sourcesOf(&bench.tables).?.state.diffs_loaded.*;
    try testing.expect(loaded & git_status.diffBit(.unstaged) != 0);
    try testing.expectEqual(cursor_before, document.cursorOf(bench.pageState()));
    try testing.expectEqual(unstaged_revision, unstaged.revision);
    try testing.expectEqual(commits_revision, commits.revision);

    // A refresh the person asks forgets the diffs and asks again for the one shown.
    try bench.act(.vcs_git_refresh);
    try answerRefresh(&bench, try expectRefresh(&bench), unstaged_status);
    _ = try diffJob(bench.queued(&storage), .unstaged);
}

test "vcs git status: the focus coming back from the diff panel refreshes nothing, from elsewhere it refreshes" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try openAnswered(&bench);
    const events = plugin.panels.Events.of(&bench.tables, plugin.panels.events_table_name);
    events.publish(.{ .unfocused = @import("git_diff.zig").panel });
    events.publish(.{ .focused = git_status.panel });
    bench.run();
    try expectNothingQueued(&bench);
    events.publish(.{ .unfocused = Atom.from("vcs_git_test_text_panel") });
    events.publish(.{ .focused = git_status.panel });
    bench.run();
    _ = try expectRefresh(&bench);
}

// ---- against a real git ------------------------------------------------------------------------

/// The runner and the panel in the editor's order, as the real-git test runs them.
pub const with_runner: sequencer.Sequencer = .{ .name = "vcs_git_real_test", .steps = &.{
    .{ .system = runner.system() },
    .{ .system = git_status.system() },
} };

/// What the real-git test adds to the bench: the process system, the clock's tables the runner
/// hears, and the editor's hook that delivers the runner's answers.
/// A folder of its own for a test's real repositories, under the developer's scratch directory
/// (`~/Projects/kpx_scratch/vcs-git-tests`, made when it is not there), never inside the
/// repository the tests run in; `cleanup` deletes it. A test with no `HOME` is skipped.
pub fn repositoryFolder() !testing.TmpDir {
    var environment = try testing.environ.createMap(testing.allocator);
    defer environment.deinit();
    const home_path = environment.get("HOME") orelse return error.SkipZigTest;
    var home_dir = try std.Io.Dir.openDirAbsolute(testing.io, home_path, .{});
    defer home_dir.close(testing.io);
    var parent_dir = try home_dir.createDirPathOpen(testing.io, "Projects/kpx_scratch/vcs-git-tests", .{});
    errdefer parent_dir.close(testing.io);
    var random_bytes: [12]u8 = undefined;
    testing.io.random(&random_bytes);
    var sub_path: [16]u8 = undefined;
    _ = std.base64.url_safe.Encoder.encode(&sub_path, &random_bytes);
    const dir = try parent_dir.createDirPathOpen(testing.io, &sub_path, .{});
    return .{ .dir = dir, .parent_dir = parent_dir, .sub_path = sub_path };
}

/// The variables that point git at a repository other than the one in its working directory,
/// which a run of the tests under a git hook or `rebase -x` inherits.
const repository_variables = [_][]const u8{ "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_PREFIX" };

extern "c" fn unsetenv(name: [*:0]const u8) c_int;

/// The test's environment for real git, from the one it runs in: `repository_variables` taken
/// out of it, and out of the process's own, which the process system starts the panel's
/// programs from where libc gives it the live one, so neither git can address the repository
/// the tests run in. The caller deinits it.
pub fn gitEnvironment() !std.process.Environ.Map {
    var environment = try testing.environ.createMap(testing.allocator);
    errdefer environment.deinit();
    for (repository_variables) |name| {
        _ = environment.swapRemove(name);
        if (builtin.link_libc) {
            const name_z = try testing.allocator.dupeZ(u8, name);
            defer testing.allocator.free(name_z);
            _ = unsetenv(name_z);
        }
    }
    return environment;
}

pub fn startProcesses(bench: *Bench, processes: *mesha_runtime.process.Processes, environment: *const std.process.Environ.Map) !void {
    const scratch = try bench.memory.tableScratchAllocator();
    try mesha_runtime.process.ensure(scratch, &bench.atoms, &bench.tables);
    try mesha.time.ensureTables(scratch, &bench.atoms, &bench.tables);
    try plugin.app_commands.Requests.ensure(scratch, &bench.atoms, &bench.tables, plugin.app_commands.commands_table_name);
    try sequencer.ensureInboxes(scratch, &bench.atoms, &bench.tables, &with_runner);
    try processes.init(testing.allocator, &bench.memory, testing.io, environment);
    bench.processes = processes;
}

/// One frame as the host runs it: what the programs did is delivered, the runner and the panel
/// run, the process system applies its requests, and the editor's hook delivers the answers.
pub fn stepReal(bench: *Bench) void {
    const processes = bench.processes.?;
    processes.deliver(&bench.tables);
    editor_sequencer.run(&bench.memory, &bench.atoms, &bench.tables, &with_runner, null);
    mesha_runtime.process.applyCommands(&bench.memory, &bench.atoms, &bench.tables, processes);
    const answers = plugin.app_commands.Requests.of(&bench.memory, &bench.tables, plugin.app_commands.commands_table_name);
    answers.drain(bench, deliverAnswer);
    bench.tables.reclaimPayloads();
}

pub fn deliverAnswer(bench: *Bench, payload: *plugin.app_commands.Payload) sequencer.Applied {
    return editor.processCmd(&bench.tables, &bench.atoms, payload);
}

/// Runs frames until the panel has nothing queued or running and, when `side` is given, holds
/// that diff; fails after a few seconds.
pub fn settleReal(bench: *Bench, side: ?git.Side) !void {
    for (0..1000) |_| {
        stepReal(bench);
        const state = bench.tables.findByName(Atom.from(git_status.state_table_name)).?;
        var rows = state.readQuery(struct { refresh_jobs: *u8, commands_running: *u8, diffs_loaded: *u8, answered: *u8 });
        const row = rows.next().?.view;
        const busy = runner.busy(&bench.tables, sequencer.inboxOf(git_status.system()));
        const loaded = if (side) |wanted| row.diffs_loaded.* & git_status.diffBit(wanted) != 0 else true;
        const idle = row.refresh_jobs.* == 0 and row.commands_running.* == 0 and !busy;
        if (row.answered.* == 1 and idle and loaded) return;
        try testing.io.sleep(.fromMilliseconds(5), .awake);
    }
    return error.Timeout;
}

/// Runs git in `directory` with `arguments` and gives what it said, in `allocator`.
pub fn runGit(allocator: std.mem.Allocator, environment: *const std.process.Environ.Map, directory: []const u8, arguments: []const []const u8) ![]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(allocator, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false" });
    try argv.appendSlice(allocator, arguments);
    const result = try std.process.run(allocator, testing.io, .{ .argv = argv.items, .cwd = .{ .path = directory }, .environ_map = environment });
    switch (result.term) {
        .exited => |code| if (code != 0) {
            std.debug.print("git {s} failed: {s}\n", .{ arguments[0], result.stderr });
            return error.GitFailed;
        },
        else => return error.GitFailed,
    }
    return result.stdout;
}

/// How a git the caller expected to fail ended.
pub const GitOutcome = enum { failed, succeeded };

/// Runs git in `directory` with `arguments`, which the caller expects to fail, printing nothing:
/// whether it failed, for the caller to assert.
pub fn runGitFailing(allocator: std.mem.Allocator, environment: *const std.process.Environ.Map, directory: []const u8, arguments: []const []const u8) !GitOutcome {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(allocator, &.{ "git", "-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false" });
    try argv.appendSlice(allocator, arguments);
    const result = try std.process.run(allocator, testing.io, .{ .argv = argv.items, .cwd = .{ .path = directory }, .environ_map = environment });
    return switch (result.term) {
        .exited => |code| if (code == 0) .succeeded else .failed,
        else => .failed,
    };
}

test "vcs git status: a discard whose changes changed before the answer runs nothing" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    const two_unstaged = "# branch.oid 5fa486e7e3477e590b3d2beb26d6f1e27a0a5b0f\x00# branch.head main\x00" ++
        "1 .M N... 100644 100644 100644 8c774644110a47745de91a91c7d99b01433a976b 8c774644110a47745de91a91c7d99b01433a976b a.txt\x00" ++
        "1 .M N... 100644 100644 100644 8c774644110a47745de91a91c7d99b01433a976b 8c774644110a47745de91a91c7d99b01433a976b b.txt\x00";
    try openAnsweredWith(&bench, two_unstaged);
    var storage: [8]runner.Job = undefined;
    var said: [8][]const u8 = undefined;

    // The heading, asked about with two files; a third appears before the answer.
    try bench.actOn(.unstaged, "Unstaged changes (2)", .vcs_git_discard);
    const heading = bench.dialog() orelse return error.NoDialog;
    try testing.expectEqualStrings("Discard all 2 unstaged changes?", heading.completions.title);
    try bench.act(.vcs_git_refresh);
    var refresh_jobs: [2]runner.Job = undefined;
    @memcpy(&refresh_jobs, bench.queued(&storage));
    _ = try bench.finish(try Bench.jobFor(&refresh_jobs, .status), 0, unstaged_status, "");
    _ = try bench.finish(try Bench.jobFor(&refresh_jobs, .recent), 0, recent_commits, "");
    bench.run();
    bench.forgetRequests();
    try bench.choose(heading, "Discard");
    try testing.expectEqual(@as(usize, 0), bench.queued(&storage).len);
    const told = bench.told(&said);
    try testing.expectEqual(@as(usize, 1), told.len);
    try testing.expectEqualStrings("It changed meanwhile; k asks again", told[0]);
}

test "vcs git status: a dismissed dialog runs nothing, and k on a conflict tells" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    const conflicted = "# branch.oid 5fa486e7e3477e590b3d2beb26d6f1e27a0a5b0f\x00# branch.head main\x00" ++
        "u UU N... 100644 100644 100644 100644 8c774644110a47745de91a91c7d99b01433a976b 8c774644110a47745de91a91c7d99b01433a976b 8c774644110a47745de91a91c7d99b01433a976b both.txt\x00" ++
        "1 .M N... 100644 100644 100644 8c774644110a47745de91a91c7d99b01433a976b 8c774644110a47745de91a91c7d99b01433a976b b.txt\x00";
    try bench.act(.vcs_git_status);
    var storage: [8]runner.Job = undefined;
    const jobs = bench.queued(&storage);
    _ = try bench.finish(try Bench.jobFor(jobs, .status), 0, conflicted, "");
    _ = try bench.finish(try Bench.jobFor(jobs, .recent), 0, recent_commits, "");
    _ = try bench.finish(try Bench.jobFor(jobs, .operation), 0, "", "");
    _ = try bench.finish(try Bench.jobFor(jobs, .root), 0, "/work/repo\n", "");
    bench.run();
    bench.forgetRequests();

    try bench.actOn(.unstaged, "b.txt", .vcs_git_discard);
    const asked = bench.dialog() orelse return error.NoDialog;
    try bench.dismiss(asked);
    try testing.expectEqual(@as(usize, 0), bench.queued(&storage).len);

    var said: [8][]const u8 = undefined;
    bench.forgetRequests();
    try bench.actOn(.unmerged, "both.txt", .vcs_git_discard);
    try testing.expect(bench.dialog() == null);
    try testing.expectEqual(@as(usize, 0), bench.queued(&storage).len);
    const told = bench.told(&said);
    try testing.expectEqual(@as(usize, 1), told.len);
    try testing.expectEqualStrings("Resolve it, or abort the merge", told[0]);
}

test "vcs git status: nothing is staged while the repository's root is not known" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try bench.act(.vcs_git_status);
    var storage: [8]runner.Job = undefined;
    const jobs = bench.queued(&storage);
    _ = try bench.finish(try Bench.jobFor(jobs, .status), 0, changed_status, "");
    _ = try bench.finish(try Bench.jobFor(jobs, .recent), 0, recent_commits, "");
    _ = try bench.finish(try Bench.jobFor(jobs, .operation), 0, "", "");
    _ = try bench.finish(try Bench.jobFor(jobs, .root), 1, "", "fatal: something\n");
    bench.run();
    bench.forgetRequests();
    // The status's paths are the root's: from a directory below it they would name other files.
    try bench.actOn(.untracked, "notes.txt", .vcs_git_stage);
    try bench.act(.vcs_git_unstage_all);
    try testing.expectEqual(@as(usize, 0), bench.queued(&storage).len);
    var said: [8][]const u8 = undefined;
    const told = bench.told(&said);
    try testing.expectEqual(@as(usize, 2), told.len);
    for (told) |sentence| try testing.expectEqualStrings("The repository's root is not known yet: g asks again", sentence);
}

/// The commit menu presented, and the panel's run; the menu's request taken.
pub fn presentCommitMenu(bench: *Bench) !transient.Presenting {
    try sequencer.deliverMessage(&bench.tables, sequencer.inboxOf(git_status.system()), Atom.from(git_commit.Msg.vcs_git_commit_menu), &.{}, &.{});
    bench.run();
    const requests = transient.Requests.of(&bench.memory, &bench.tables, transient.requests_table_name);
    var sent: [4]transient.Request = undefined;
    const presenting = requests.peek(&sent)[0].present;
    requests.reset();
    return presenting;
}

/// `f` chosen in the commit menu `presenting`, answered as the menu answers, but not run: the
/// panel's next run takes it with whatever else was delivered.
pub fn deliverFixupChoice(bench: *Bench, presenting: transient.Presenting) !void {
    var state = presenting.state;
    var chosen_id: ?u32 = null;
    switch (ui.transient.press(&git_commit.menu, &state, "f")) {
        .chosen => |id| chosen_id = id,
        .pending, .toggled, .unbound, .wants_value, .menu => {},
    }
    const chosen: transient.Chosen = .{ .id = chosen_id.?, .cancelled = 0, .state = state };
    try sequencer.deliverMessage(&bench.tables, presenting.reply.inbox, presenting.reply.tag, presenting.reply.user_data.bytes, std.mem.asBytes(&chosen));
}

/// Expects no command of the panel's queued: a fixup among them.
pub fn expectNoCommand(bench: *Bench) !void {
    var storage: [8]runner.Job = undefined;
    for (bench.queued(&storage)) |job| try testing.expect(Bench.purposeOf(job) != .command);
}

test "vcs git status: c f in the run whose refresh took the status's commit away makes no fixup; the next run does" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try openAnswered(&bench);
    try bench.placeCursor(try bench.spotOf(.recent, "72f25b6"));
    try bench.act(.vcs_git_refresh);
    var storage: [8]runner.Job = undefined;
    const jobs = bench.queued(&storage);
    const status_job = try Bench.jobFor(jobs, .status);
    const recent_job = try Bench.jobFor(jobs, .recent);
    const menu_shown = try presentCommitMenu(&bench);
    bench.forgetRequests();
    // The refresh's answers, `72f25b6` gone from the recent commits and another in its place,
    // and `c f`, in one run.
    const start_hash = "3333333333333333333333333333333333333333";
    const replaced = "5fa486e7e3477e590b3d2beb26d6f1e27a0a5b0f\x1f5fa486e\x1fAna\x1f2026-11-20\x1fHEAD -> main\x1fTeach the panel its sections\x00" ++
        start_hash ++ "\x1f3333333\x1fAna\x1f2026-11-20\x1f\x1fStart\x00";
    _ = try bench.finish(status_job, 0, changed_status, "");
    _ = try bench.finish(recent_job, 0, replaced, "");
    try deliverFixupChoice(&bench, menu_shown);
    bench.run();
    try expectNoCommand(&bench);
    var waiting: [8][]const u8 = undefined;
    try testing.expectEqualStrings("The status changed under the cursor", bench.told(&waiting)[0]);
    bench.forgetRequests();
    try deliverFixupChoice(&bench, try presentCommitMenu(&bench));
    bench.run();
    _ = try expectCommand(&bench, .{ .commit = .{ .kind = .fixup, .target = start_hash } }, "");
}
