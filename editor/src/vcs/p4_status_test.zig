//! Tests of vcs-p4's system (`p4_status.zig`) and its parts, run alone over their tables: a job
//! it queues is read from the runner's requests, and its answer is given as the runner gives it,
//! a finished job's row with a stand-in program whose kept output is the test's literal: tagged
//! output written from Perforce's documentation (`p4_test.zig`'s fixtures' shapes), never a real
//! server's. Each job's command line, input and environment are asserted.

const std = @import("std");
const mesha = @import("mesha");
const mesha_runtime = @import("mesha_runtime");
const Atom = mesha.Atom;
const Table = mesha.Table;
const plugin = mesha.plugin;
const process = mesha.process;
const sequencer = mesha.sequencer;
const editor_sequencer = @import("../editor_sequencer.zig");
const action_palette = @import("../action_palette.zig");
const transient = @import("../transient.zig");
const text_panel = @import("../text_panel.zig");
const shared = @import("../text_editor.zig");
const runner = @import("runner.zig");
const vcs_page = @import("page.zig");
const p4 = @import("p4.zig");
const p4_status = @import("p4_status.zig");
const p4_diff = @import("p4_diff.zig");
const p4_change = @import("p4_change.zig");
const status_test = @import("git_status_test.zig");
const document = @import("../document/document.zig");
const document_sources = @import("../document/sources.zig");
const testing = std.testing;
const text_editor = plugin.text_editor_api;
const Msg = p4_status.Msg;

/// The workspace's root and its name, as `info` says them.
const root = "/work/repo";
const client = "bruno_ws";

const info_said =
    "... userName bruno\n" ++
    "... clientName bruno_ws\n" ++
    "... clientRoot /work/repo\n" ++
    "... serverAddress ssl:perforce.example.com:1666\n" ++
    "\n";

/// `info` with no workspace: `p4_info.html`'s example names the host and has no root.
const info_no_workspace =
    "... userName bruno\n" ++
    "... clientName myserver-24-n102\n" ++
    "... serverAddress ssl:perforce.example.com:1666\n" ++
    "\n";

const pending_said =
    "... change 1234\n... time 1700000000\n... user bruno\n... client bruno_ws\n... status pending\n" ++
    "... desc Fix the frame\nand its border\n\n" ++
    "... change 1240\n... time 1700000100\n... user bruno\n... client bruno_ws\n... status pending\n" ++
    "... desc Docs\n\n";

const shelved_said =
    "... change 1250\n... time 1700000200\n... user bruno\n... client bruno_ws\n... status shelved\n" ++
    "... desc Nothing yet\n\n";

const opened_said =
    "... depotFile //depot/main/a.zig\n... clientFile /work/repo/src/a.zig\n... action edit\n... change default\n... type text\n\n" ++
    "... depotFile //depot/main/b.zig\n... clientFile /work/repo/src/b.zig\n... action edit\n... change 1234\n... type text\n\n" ++
    "... depotFile //depot/main/c.zig\n... clientFile /work/repo/src/c.zig\n... action add\n... change 1234\n... type text\n\n" ++
    "... depotFile //depot/main/d.zig\n... clientFile /work/repo/src/d.zig\n... action integrate\n... change 1240\n... type text\n... unresolved 1\n\n";

const submitted_said =
    "... change 1200\n... time 1699000000\n... user ana\n... client ana_ws\n... status submitted\n... desc Earlier work\n\n";

const described_said =
    "... change 1250\n... time 1700000200\n... user bruno\n... client bruno_ws\n... status shelved\n... desc Nothing yet\n" ++
    "... depotFile0 //depot/main/e.zig\n... action0 edit\n... type0 text\n... rev0 3\n" ++
    "... depotFile1 //depot/main/f.zig\n... action1 add\n... type1 text\n... rev1 none\n\n";

/// vcs-p4's system alone over its tables, with vcs-git's bench's stand-in programs and the text
/// editor, whose requests are applied when a test says.
const Bench = struct {
    base: status_test.Bench = .{},
    editors: mesha_runtime.text_editor.TextEditor = undefined,

    fn init(bench: *Bench) !void {
        try bench.base.init();
        const scratch = try bench.base.memory.tableScratchAllocator();
        try p4_status.ensure(scratch, &bench.base.atoms, &bench.base.tables);
        try text_panel.ensure(scratch, &bench.base.atoms, &bench.base.tables);
        try mesha_runtime.text_editor.ensure(scratch, &bench.base.atoms, &bench.base.tables);
        try bench.editors.init(testing.allocator, &bench.base.memory, testing.io);
        const alone: sequencer.Sequencer = .{ .name = "vcs_p4_test", .steps = &.{.{ .system = p4_status.system() }} };
        try sequencer.ensureInboxes(scratch, &bench.base.atoms, &bench.base.tables, &alone);
        const state = bench.pageState();
        state.document_view_width.* = 800;
        state.document_view_height.* = 600;
    }

    fn deinit(bench: *Bench) void {
        bench.editors.deinit(&bench.base.tables);
        bench.base.deinit();
    }

    fn run(bench: *Bench) void {
        const solo = sequencer.Solo.of("vcs_p4_test", p4_status.system());
        editor_sequencer.run(&bench.base.memory, &bench.base.atoms, &bench.base.tables, &solo.sequencer(), null);
        bench.base.tables.reclaimPayloads();
    }

    fn act(bench: *Bench, tag: anytype) !void {
        const inbox = sequencer.inboxOf(p4_status.system());
        try sequencer.deliverMessage(&bench.base.tables, inbox, Atom.from(tag), &.{}, &.{});
        bench.run();
    }

    fn queued(bench: *Bench, into: []runner.Job) []runner.Job {
        return bench.base.queued(into);
    }

    /// The job queued for `purpose` among the requests since they were last forgotten.
    fn job(bench: *Bench, purpose: p4_status.Purpose) !runner.Job {
        var jobs: [32]runner.Job = undefined;
        for (bench.queued(&jobs)) |queued_job| {
            if (purposeOf(queued_job) == purpose) return queued_job;
        }
        return error.NotQueued;
    }

    /// `job` answered with `code`, having said `said`, and the system's run.
    fn answer(bench: *Bench, queued_job: runner.Job, code: i32, said: []const u8) !void {
        _ = try bench.base.finish(queued_job, code, said, if (code == 0) "" else "p4: an error\n");
        bench.run();
    }

    /// `job` answered as a program that could not be started.
    fn answerUnstarted(bench: *Bench, queued_job: runner.Job) !void {
        bench.base.serial += 1;
        const jobs = bench.base.tables.findByName(Atom.from(runner.jobs_table_name)).?;
        _ = try jobs.tryInsert(.{
            .serial = bench.base.serial,
            .owner = queued_job.owner.inbox,
            .reply_tag = queued_job.owner.tag,
            .reply_user_data = queued_job.owner.user_data.bytes,
            .state = @as(u8, @intFromEnum(runner.JobState.finished)),
            .order = @as(u8, @intFromEnum(queued_job.order)),
            .process = @as(u32, 0),
            .argv = queued_job.argv,
            .input = queued_job.input,
            .environment = queued_job.environment,
            .directory = queued_job.directory,
            .shown = queued_job.shown,
        });
        const finished: runner.Finished = .{ .job = bench.base.serial, .code = -1, .started = @intFromEnum(process.SpawnResult.not_found) };
        try sequencer.deliverMessage(&bench.base.tables, queued_job.owner.inbox, queued_job.owner.tag, queued_job.owner.user_data.bytes, std.mem.asBytes(&finished));
        bench.run();
    }

    /// The panel opened, `info` and the four lists answered as the fixtures say, and the
    /// shelved files: the page as a person first sees it.
    fn open(bench: *Bench) !void {
        try bench.act(Msg.vcs_p4_status);
        const info = try bench.job(.info);
        bench.base.forgetRequests();
        try bench.answer(info, 0, info_said);
        try bench.answerLists(pending_said, opened_said);
    }

    /// The four lists answered, `pending` and `opened` as given, then the shelved files.
    fn answerLists(bench: *Bench, pending: []const u8, opened: []const u8) !void {
        const lists = [_]struct { purpose: p4_status.Purpose, said: []const u8 }{
            .{ .purpose = .pending, .said = pending },
            .{ .purpose = .shelved_changes, .said = shelved_said },
            .{ .purpose = .opened, .said = opened },
            .{ .purpose = .submitted, .said = submitted_said },
        };
        var jobs: [4]runner.Job = undefined;
        for (lists, &jobs) |list, *slot| slot.* = try bench.job(list.purpose);
        bench.base.forgetRequests();
        for (lists, jobs) |list, list_job| try bench.answer(list_job, 0, list.said);
        const described = try bench.job(.describe_shelved);
        bench.base.forgetRequests();
        try bench.answer(described, 0, described_said);
    }

    /// `g` asks `info` again and the lists, all answered as the fixtures say.
    fn refreshFromInfo(bench: *Bench) !void {
        bench.base.forgetRequests();
        try bench.act(Msg.vcs_p4_refresh);
        const info = try bench.job(.info);
        bench.base.forgetRequests();
        try bench.answer(info, 0, info_said);
        try bench.answerLists(pending_said, opened_said);
    }

    const Presented = status_test.Bench.Presented;

    /// `g`, every list answered as the fixtures say but `pending` and `opened`.
    fn refreshWith(bench: *Bench, pending: []const u8, opened: []const u8) !void {
        bench.base.forgetRequests();
        try bench.act(Msg.vcs_p4_refresh);
        try bench.answerLists(pending, opened);
    }

    fn pageState(bench: *Bench) document.StateRow {
        const state = bench.base.tables.findByName(Atom.from(p4_status.state_table_name)).?;
        return state.getRow(.{ .row = 0, .generation = state.rowGeneration(0) }, document.StateRow).?;
    }

    fn laidOut(bench: *Bench) !document.Layout {
        return vcs_page.laidOutIn(bench.base.arena.allocator(), &bench.base.tables, &bench.base.atoms, p4_status.status_page);
    }

    fn at(bench: *Bench) !document.At {
        const page = try bench.laidOut();
        return document.at(page, document.cursorOf(bench.pageState()));
    }

    fn value(bench: *Bench, name: []const u8) ?[]const u8 {
        return bench.base.value(name);
    }

    /// The headings the page shows, in order, their text in the arena.
    fn headings(bench: *Bench) ![]const []const u8 {
        const page = try bench.laidOut();
        var found: std.ArrayList([]const u8) = .empty;
        for (page.shown) |index| {
            const block = page.blocks[index];
            if (block.kind != .heading) continue;
            try found.append(bench.base.arena.allocator(), block.text);
        }
        return found.items;
    }

    /// The cursor put on the heading whose text begins `text`.
    fn onHeading(bench: *Bench, text: []const u8) !void {
        const page = try bench.laidOut();
        for (page.shown) |index| {
            const block = page.blocks[index];
            if (block.kind != .heading or !std.mem.startsWith(u8, block.text, text)) continue;
            document.setCursor(bench.pageState(), .{ .block = block.key, .index = block.first_stop });
            return;
        }
        return error.NoSuchHeading;
    }

    /// The cursor put on the row of the file `depot_path` in changelist `change`.
    fn onFile(bench: *Bench, depot_path: []const u8, change: []const u8) !void {
        const page = try bench.laidOut();
        const table_name = if (std.mem.eql(u8, change, "default")) p4_status.default_table_name else p4_status.opened_table_name;
        const table = bench.base.tables.findByName(Atom.from(table_name)).?;
        var rows = table.readQuery(p4_status.FileRow);
        const handle = while (rows.next()) |row| {
            if (std.mem.eql(u8, row.view.depot_path, depot_path)) break row.handle;
        } else return error.NoSuchFile;
        for (page.blocks) |block| {
            const table_block = block.table orelse continue;
            if (table_block.table != table) continue;
            if (block.group) |group| {
                if (!std.mem.eql(u8, group.key_text, change)) continue;
                const placed = document.cursorOnGroup(page, group.block, change, handle) orelse return error.NoSuchGroup;
                document.setCursor(bench.pageState(), placed);
                return;
            }
            document.setCursor(bench.pageState(), document.cursorOnRow(page, block.key, handle));
            return;
        }
        return error.NoSuchFile;
    }

    fn told(bench: *Bench, sentence: []const u8) bool {
        var lines: [32][]const u8 = undefined;
        for (bench.base.told(&lines)) |line| {
            if (std.mem.eql(u8, line, sentence)) return true;
        }
        return false;
    }

    fn toldBeginning(bench: *Bench, beginning: []const u8) bool {
        var lines: [32][]const u8 = undefined;
        for (bench.base.told(&lines)) |line| {
            if (std.mem.startsWith(u8, line, beginning)) return true;
        }
        return false;
    }

    /// The person chose `label` in the dialog or prompt presented, and the system's run.
    fn choose(bench: *Bench, label: []const u8) !void {
        const presented = bench.base.dialog() orelse return error.NoDialog;
        const chosen = for (presented.completions.entries) |entry| {
            if (std.mem.eql(u8, entry.label, label)) break entry;
        } else return error.NoSuchEntry;
        const payload = try plugin.editor_api.eventPayload(bench.base.arena.allocator(), .{ .kind = .completed, .completion = chosen, .query = "" });
        bench.base.dialogs().reset();
        try sequencer.deliverMessage(&bench.base.tables, presented.reply.inbox, presented.reply.tag, presented.reply.user_data.bytes, payload);
        bench.run();
    }

    /// The text editor applies the requests waiting, as after a frame.
    fn applyText(bench: *Bench) void {
        mesha_runtime.text_editor.applyCommands(&bench.base.memory, &bench.base.atoms, &bench.base.tables, &bench.editors);
    }

    /// The person writes `text` in the description buffer, in place of what it held.
    fn write(bench: *Bench, text: []const u8) void {
        bench.editors.apply(&bench.base.tables, .{ .set_text = .{ .buffer = p4_change.message_buffer, .text = text } });
        bench.editors.publish(&bench.base.tables);
    }

    fn description(bench: *Bench) !?[]const u8 {
        if (text_editor.tableOf(&bench.base.tables, p4_change.message_buffer) == null) return null;
        return try shared.textOf(&bench.base.tables, p4_change.message_buffer);
    }

    fn sourceState(bench: *Bench, name: []const u8) document_sources.SourceState {
        const sources = bench.base.tables.findByName(Atom.from(document_sources.sources_table_name)).?;
        var rows = sources.readQuery(struct { name: []const u8, state: *u8 });
        while (rows.next()) |row| {
            if (std.mem.eql(u8, row.view.name, name)) return @enumFromInt(row.view.state.*);
        }
        return .ok;
    }
};

fn purposeOf(queued_job: runner.Job) p4_status.Purpose {
    const data = std.mem.bytesToValue(p4_status.JobData, queued_job.owner.user_data.bytes[0..@sizeOf(p4_status.JobData)]);
    return @enumFromInt(data.purpose);
}

fn commandOf(queued_job: runner.Job) p4_status.CommandName {
    const data = std.mem.bytesToValue(p4_status.JobData, queued_job.owner.user_data.bytes[0..@sizeOf(p4_status.JobData)]);
    return @enumFromInt(data.command);
}

test "vcs p4: opening vcs-p4 runs info, then changes and fstat together" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try bench.act(Msg.vcs_p4_status);
    var jobs: [8]runner.Job = undefined;
    const first = bench.queued(&jobs);
    try testing.expectEqual(@as(usize, 1), first.len);
    try testing.expectEqualStrings("p4\x1f-ztag\x1finfo", first[0].argv);
    try testing.expectEqualStrings("", first[0].input);
    try testing.expectEqualStrings("", first[0].environment);
    try testing.expectEqualStrings("Loading...", bench.value("vcs-p4.note").?);
    const info = first[0];
    bench.base.forgetRequests();
    try bench.answer(info, 0, info_said);
    const lists = bench.queued(&jobs);
    try testing.expectEqual(@as(usize, 4), lists.len);
    const expected = [_][]const u8{
        "p4\x1f-ztag\x1f-c\x1fbruno_ws\x1fchanges\x1f-s\x1fpending\x1f-l\x1f-c\x1fbruno_ws",
        "p4\x1f-ztag\x1f-c\x1fbruno_ws\x1fchanges\x1f-s\x1fshelved\x1f-l\x1f-c\x1fbruno_ws",
        "p4\x1f-ztag\x1f-c\x1fbruno_ws\x1ffstat\x1f-Ro\x1f//bruno_ws/...",
        "p4\x1f-ztag\x1f-c\x1fbruno_ws\x1fchanges\x1f-s\x1fsubmitted\x1f-l\x1f-m\x1f10\x1f//bruno_ws/...",
    };
    for (lists, expected) |list, argv| {
        try testing.expectEqualStrings(argv, list.argv);
        try testing.expectEqualStrings("", list.input);
        try testing.expectEqual(runner.Order.shared, list.order);
    }
    try testing.expectEqualStrings("bruno_ws", bench.value("vcs-p4.client").?);
    try testing.expectEqualStrings("bruno", bench.value("vcs-p4.user").?);
    try testing.expectEqualStrings("ssl:perforce.example.com:1666", bench.value("vcs-p4.server").?);
    // Only once all four answered: one `describe -S -s` for the changelists with shelved files,
    // their numbers on its input.
    var answered: [4]runner.Job = undefined;
    @memcpy(&answered, lists);
    bench.base.forgetRequests();
    const saids = [_][]const u8{ pending_said, shelved_said, opened_said, submitted_said };
    for (answered[0..3], saids[0..3]) |list, said| try bench.answer(list, 0, said);
    try testing.expectEqual(@as(usize, 0), bench.queued(&jobs).len);
    try bench.answer(answered[3], 0, saids[3]);
    const described = try bench.job(.describe_shelved);
    try testing.expectEqualStrings("p4\x1f-ztag\x1f-c\x1fbruno_ws\x1f-x\x1f-\x1fdescribe\x1f-S\x1f-s", described.argv);
    try testing.expectEqualStrings("1250\n", described.input);
}

test "vcs p4: the files of two changelists land under their own headings" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try bench.open();
    const shown = try bench.headings();
    const expected = [_][]const u8{
        "Default changelist (1)",
        "Pending changelists (3)",
        // A changelist with no shelf leaves its heading two spaces after its count, unseen.
        "Change 1234  Fix the frame (2)  ",
        "Change 1240  Docs (1)  ",
        "Change 1250  Nothing yet (0)  2 shelved",
        "Recent submitted changes",
    };
    try testing.expectEqual(expected.len, shown.len);
    for (expected, shown) |want, got| try testing.expectEqualStrings(want, got);
    // A file is shown from the workspace's root; an unresolved one says so.
    try bench.onFile("//depot/main/d.zig", "1240");
    const at = try bench.at();
    const row = at.row.table.getRow(at.row.row, p4_status.FileRow).?;
    try testing.expectEqualStrings("src/d.zig", row.path);
    try testing.expectEqualStrings("integrate (unresolved)", row.action);
    try testing.expectEqualStrings("1240", at.row.group.?.key_text);
    try testing.expectEqualStrings("", bench.value("vcs-p4.note").?);
    try testing.expectEqualStrings("", bench.value("vcs-p4.unlisted").?);
}

test "vcs p4: a failed refresh keeps the rows and marks the sources unread; a session that ended is told with what to run" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try bench.open();
    try bench.onHeading("Change 1240");
    _ = try bench.act(Msg.vcs_p4_toggle);
    bench.base.forgetRequests();
    try bench.act(Msg.vcs_p4_refresh);
    var jobs: [4]runner.Job = undefined;
    for (&jobs, [_]p4_status.Purpose{ .pending, .shelved_changes, .opened, .submitted }) |*slot, purpose| slot.* = try bench.job(purpose);
    bench.base.forgetRequests();
    try bench.answer(jobs[0], 1, "");
    for (jobs[1..]) |list| try bench.answer(list, 0, "");
    // Every row kept, every source unread, the reason in the note.
    const shown = try bench.headings();
    try testing.expectEqualStrings("Change 1234  Fix the frame (2)  ", shown[2]);
    try testing.expectEqual(document_sources.SourceState.unread, bench.sourceState("vcs-p4.opened"));
    try testing.expectEqual(document_sources.SourceState.unread, bench.sourceState("vcs-p4.changelists"));
    try testing.expectEqualStrings("p4 changes failed; $ shows why", bench.value("vcs-p4.note").?);
    try testing.expect(bench.told("p4 changes failed; $ shows why"));
    // The fold of 1240 survived.
    try testing.expectEqual(@as(usize, 1), bench.base.tables.findByName(Atom.from(p4_status.folds_table_name)).?.count());
    // Did the session end? `info` and `login -s`, by their exit codes.
    const session_info = try bench.job(.session_info);
    const login = try bench.job(.login_status);
    try testing.expectEqualStrings("p4\x1f-ztag\x1f-c\x1fbruno_ws\x1flogin\x1f-s", login.argv);
    bench.base.forgetRequests();
    try bench.answer(session_info, 0, info_said);
    try bench.answer(login, 1, "");
    const ended = "The Perforce session has ended: Run p4 login in a terminal, then g";
    try testing.expectEqualStrings(ended, bench.value("vcs-p4.note").?);
    try testing.expect(bench.told(ended));
    // A second failed refresh says it in the note, and does not tell it again.
    bench.base.forgetRequests();
    try bench.act(Msg.vcs_p4_refresh);
    for (&jobs, [_]p4_status.Purpose{ .pending, .shelved_changes, .opened, .submitted }) |*slot, purpose| slot.* = try bench.job(purpose);
    bench.base.forgetRequests();
    for (jobs) |list| try bench.answer(list, 1, "");
    const again_info = try bench.job(.session_info);
    const again_login = try bench.job(.login_status);
    bench.base.forgetRequests();
    try bench.answer(again_info, 0, info_said);
    try bench.answer(again_login, 1, "");
    try testing.expectEqualStrings(ended, bench.value("vcs-p4.note").?);
    try testing.expect(!bench.told(ended));
    // Signed in again, a refresh that reads clears the note and the marks.
    try bench.refreshWith(pending_said, opened_said);
    try testing.expectEqualStrings("", bench.value("vcs-p4.note").?);
    try testing.expectEqual(document_sources.SourceState.ok, bench.sourceState("vcs-p4.opened"));
    try testing.expectEqual(@as(usize, 1), bench.base.tables.findByName(Atom.from(p4_status.folds_table_name)).?.count());
}

test "vcs p4: no workspace, and no p4, are each a note, and nothing else runs" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try bench.act(Msg.vcs_p4_status);
    const info = try bench.job(.info);
    bench.base.forgetRequests();
    try bench.answer(info, 0, info_no_workspace);
    var jobs: [4]runner.Job = undefined;
    try testing.expectEqual(@as(usize, 0), bench.queued(&jobs).len);
    try testing.expect(std.mem.startsWith(u8, bench.value("vcs-p4.note").?, "No workspace here: p4 info names no client workspace with a root"));
    // A command refuses without a workspace.
    try bench.act(Msg.vcs_p4_resolve);
    try testing.expectEqual(@as(usize, 0), bench.queued(&jobs).len);
    // `g` asks `info` again: `p4` is not on PATH.
    try bench.act(Msg.vcs_p4_refresh);
    const again = try bench.job(.info);
    bench.base.forgetRequests();
    try bench.answerUnstarted(again);
    try testing.expectEqualStrings("p4 could not be run: it was not found on PATH", bench.value("vcs-p4.note").?);
    try testing.expectEqual(@as(usize, 0), bench.queued(&jobs).len);
    try testing.expectEqual(@as(usize, 0), (try bench.headings()).len);
}

test "vcs p4: s shows the form, and C-c C-c submits by number" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try bench.open();
    // Refused from the panel's rows first: a changelist with an unresolved file, an empty one.
    try bench.onHeading("Change 1240");
    try bench.act(Msg.vcs_p4_submit);
    try testing.expect(bench.toldBeginning("change 1240 has 1 file waiting for a resolve"));
    try bench.onHeading("Change 1250");
    try bench.act(Msg.vcs_p4_submit);
    try testing.expect(bench.told("change 1250 has no files to submit"));
    // 1234: its description in the buffer.
    try bench.onHeading("Change 1234");
    bench.base.forgetRequests();
    try bench.act(Msg.vcs_p4_submit);
    try testing.expect(bench.told("Submitting change 1234: 2 files (src/b.zig, src/c.zig); C-c C-c submits them, C-c C-k gives it up"));
    bench.applyText();
    try testing.expectEqualStrings("Fix the frame\nand its border", (try bench.description()).?);
    // C-c C-c reads the changelists again first; nothing is submitted before they answer.
    try bench.act(p4_change.Msg.vcs_p4_message_finish);
    try testing.expectError(error.NotQueued, bench.job(.command));
    try bench.answerLists(pending_said, opened_said);
    // Unchanged: one program, `submit -c 1234`.
    const submit = try bench.job(.command);
    try testing.expectEqualStrings("p4\x1f-ztag\x1f-c\x1fbruno_ws\x1fsubmit\x1f-c\x1f1234", submit.argv);
    try testing.expectEqualStrings("", submit.input);
    try testing.expectEqual(runner.Order.alone, submit.order);
    bench.base.forgetRequests();
    try bench.answer(submit, 0, "... change 1234\n... submittedChange 1234\n");
    try testing.expect(bench.toldBeginning("Submitted change 1234"));
}

test "vcs p4: a description being written replaced by another s, e or N is said to be given up" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try bench.open();
    try bench.onHeading("Change 1234");
    try bench.act(Msg.vcs_p4_submit);
    bench.applyText();
    // `e` on the same changelist: another purpose.
    bench.base.forgetRequests();
    try bench.act(Msg.vcs_p4_describe);
    try testing.expect(bench.told("The description being written for change 1234 was given up"));
    bench.applyText();
    // `s` on the default changelist.
    try bench.onHeading("Default changelist");
    bench.base.forgetRequests();
    try bench.act(Msg.vcs_p4_submit);
    try testing.expect(bench.told("The description being written for change 1234 was given up. Submitting the default changelist: 1 file (src/a.zig); C-c C-c submits them, C-c C-k gives it up"));
    bench.applyText();
    // `N`.
    bench.base.forgetRequests();
    try bench.act(Msg.vcs_p4_new_change);
    try testing.expect(bench.told("The description being written for the default changelist was given up"));
    bench.applyText();
    // `N` again: the same purpose and changelist, shown again, nothing given up.
    bench.base.forgetRequests();
    try bench.act(Msg.vcs_p4_new_change);
    try testing.expect(!bench.toldBeginning("The description being written"));
}

test "vcs p4: a changed description is saved with change -i before submit -c, which waits on it" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try bench.open();
    try bench.onFile("//depot/main/b.zig", "1234");
    try bench.act(Msg.vcs_p4_submit);
    bench.applyText();
    bench.write("Fix the frame\n\n- Starts with a dash, and: a colon");
    bench.base.forgetRequests();
    try bench.act(p4_change.Msg.vcs_p4_message_finish);
    try bench.answerLists(pending_said, opened_said);
    const form_job = try bench.job(.command);
    try testing.expectEqualStrings("p4\x1f-c\x1fbruno_ws\x1fchange\x1f-o\x1f1234", form_job.argv);
    try testing.expectEqual(p4_status.CommandName.change_form, commandOf(form_job));
    bench.base.forgetRequests();
    const form = "Change:\t1234\n\nClient:\tbruno_ws\n\nUser:\tbruno\n\nStatus:\tpending\n\nDescription:\n\tFix the frame\n\tand its border\n\nFiles:\n\t//depot/main/b.zig\t# edit\n\t//depot/main/c.zig\t# add\n";
    try bench.answer(form_job, 0, form);
    const save = try bench.job(.command);
    try testing.expectEqualStrings("p4\x1f-c\x1fbruno_ws\x1fchange\x1f-i", save.argv);
    // The description is on the input, in the form, never an argument; the files kept.
    try testing.expect(std.mem.indexOf(u8, save.argv, "dash") == null);
    try testing.expectEqualStrings("Change:\t1234\n\nClient:\tbruno_ws\n\nUser:\tbruno\n\nStatus:\tpending\n\nDescription:\n\tFix the frame\n\t\n\t- Starts with a dash, and: a colon\n\nFiles:\n\t//depot/main/b.zig\t# edit\n\t//depot/main/c.zig\t# add\n", save.input);
    // A failed `change -i` stops there: no submit, the buffer kept.
    bench.base.forgetRequests();
    try bench.answer(save, 1, "");
    var jobs: [8]runner.Job = undefined;
    for (bench.queued(&jobs)) |queued_job| try testing.expect(purposeOf(queued_job) != .command);
    try testing.expect(bench.toldBeginning("p4 change -i failed"));
    bench.applyText();
    try testing.expect((try bench.description()) != null);
}

test "vcs p4: the default changelist's submit sends the form on input, and a failed one is listed again and told" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try bench.open();
    try bench.onHeading("Default changelist");
    try bench.act(Msg.vcs_p4_submit);
    bench.applyText();
    try testing.expectEqualStrings("", (try bench.description()).?);
    bench.write("Ship a.zig");
    bench.base.forgetRequests();
    try bench.act(p4_change.Msg.vcs_p4_message_finish);
    try bench.answerLists(pending_said, opened_said);
    const form_job = try bench.job(.command);
    try testing.expectEqualStrings("p4\x1f-c\x1fbruno_ws\x1fchange\x1f-o", form_job.argv);
    bench.base.forgetRequests();
    const form = "Change:\tnew\n\nClient:\tbruno_ws\n\nUser:\tbruno\n\nStatus:\tnew\n\nDescription:\n\t<enter description here>\n\nFiles:\n\t//depot/main/a.zig\t# edit\n";
    try bench.answer(form_job, 0, form);
    const submit = try bench.job(.command);
    try testing.expectEqualStrings("p4\x1f-ztag\x1f-c\x1fbruno_ws\x1fsubmit\x1f-i", submit.argv);
    try testing.expect(std.mem.indexOf(u8, submit.argv, "Ship") == null);
    try testing.expectEqualStrings("Change:\tnew\n\nClient:\tbruno_ws\n\nUser:\tbruno\n\nStatus:\tnew\n\nDescription:\n\tShip a.zig\n\nFiles:\n\t//depot/main/a.zig\t# edit\n", submit.input);
    // It fails: the changelists are asked again, it is told, and C-c C-c will not send `-i`.
    bench.base.forgetRequests();
    try bench.answer(submit, 1, "");
    try testing.expect(bench.told(submit_failed));
    // The refresh after it lists a changelist the server numbered, holding a.zig, its own
    // description another (whether the server keeps the typed one is UNVERIFIED).
    const numbered = pending_said ++ "... change 1261\n... time 1700000300\n... user bruno\n... client bruno_ws\n... status pending\n... desc <enter description here>\n\n";
    const moved = "... depotFile //depot/main/a.zig\n... clientFile /work/repo/src/a.zig\n... action edit\n... change 1261\n... type text\n\n" ++ comptime opened_said[std.mem.indexOf(u8, opened_said, "... depotFile //depot/main/b.zig").?..];
    try bench.answerLists(numbered, moved);
    bench.base.forgetRequests();
    try bench.act(p4_change.Msg.vcs_p4_message_finish);
    try testing.expect(bench.told(refused_after_failure));
    var jobs: [8]runner.Job = undefined;
    try testing.expectEqual(@as(usize, 0), bench.queued(&jobs).len);
    // `s` on that changelist begins a description of it holding what was typed, told, and
    // C-c C-c saves it to 1261 (change -o, change -i) and submits it by number.
    try bench.onHeading("Change 1261");
    try bench.act(Msg.vcs_p4_submit);
    try testing.expect(bench.told("Submitting change 1261: 1 file (src/a.zig); the buffer holds what you typed: C-c C-c saves it to the changelist and submits"));
    bench.applyText();
    try testing.expectEqualStrings("Ship a.zig", (try bench.description()).?);
    bench.base.forgetRequests();
    try bench.act(p4_change.Msg.vcs_p4_message_finish);
    try bench.answerLists(numbered, moved);
    const form_1261 = try bench.job(.command);
    try testing.expectEqualStrings("p4\x1f-c\x1fbruno_ws\x1fchange\x1f-o\x1f1261", form_1261.argv);
    bench.base.forgetRequests();
    try bench.answer(form_1261, 0, "Change:\t1261\n\nDescription:\n\t<enter description here>\n\nFiles:\n\t//depot/main/a.zig\t# edit\n");
    const save = try bench.job(.command);
    try testing.expect(std.mem.indexOf(u8, save.input, "\tShip a.zig\n") != null);
    bench.base.forgetRequests();
    try bench.answer(save, 0, "Change 1261 updated.\n");
    const again = try bench.job(.command);
    try testing.expectEqualStrings("p4\x1f-ztag\x1f-c\x1fbruno_ws\x1fsubmit\x1f-c\x1f1261", again.argv);
    bench.base.forgetRequests();
    try bench.answer(again, 0, "");
    try testing.expect(bench.toldBeginning("Submitted change 1261"));
}

/// What is told after a default changelist's submit did not go through.
const submit_failed = "The submit did not go through ($ shows why). If Perforce numbered the changelist it is listed now: put the cursor on it and press s; otherwise s on the default changelist again. What you typed is kept.";
/// What C-c C-c tells after it, the same form never sent again.
const refused_after_failure = "The default changelist's submit did not go through, or was given up while it ran: s on the changelist its files are in now (a numbered one, or the default again); what you typed is kept";

/// `s` on the default changelist, `typed` written, C-c C-c, its refresh, `change -o`: the
/// `submit -i` job, not answered.
fn submitDefault(bench: *Bench, typed: []const u8) !runner.Job {
    try bench.onHeading("Default changelist");
    try bench.act(Msg.vcs_p4_submit);
    bench.applyText();
    if (typed.len != 0) bench.write(typed);
    bench.base.forgetRequests();
    try bench.act(p4_change.Msg.vcs_p4_message_finish);
    try bench.answerLists(pending_said, opened_said);
    const form_job = try bench.job(.command);
    bench.base.forgetRequests();
    try bench.answer(form_job, 0, "Change:\tnew\n\nDescription:\n\t<enter description here>\n\nFiles:\n\t//depot/main/a.zig\t# edit\n");
    const submit = try bench.job(.command);
    try testing.expectEqual(p4_status.CommandName.submit, commandOf(submit));
    bench.base.forgetRequests();
    return submit;
}

test "vcs p4: after a default submit that failed, s on a changelist with other files begins from its own description and says what was typed is dropped" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try bench.open();
    const submit = try submitDefault(&bench, "Ship a.zig");
    try bench.answer(submit, 1, "");
    try testing.expect(bench.told(submit_failed));
    const numbered = pending_said ++ "... change 1261\n... time 1700000300\n... user bruno\n... client bruno_ws\n... status pending\n... desc <enter description here>\n\n";
    const moved = "... depotFile //depot/main/a.zig\n... clientFile /work/repo/src/a.zig\n... action edit\n... change 1261\n... type text\n\n" ++ comptime opened_said[std.mem.indexOf(u8, opened_said, "... depotFile //depot/main/b.zig").?..];
    try bench.answerLists(numbered, moved);
    // Change 1234 holds b.zig and c.zig, not what was submitted: its own description, and the
    // typed text said to be dropped.
    bench.base.forgetRequests();
    try bench.onHeading("Change 1234");
    try bench.act(Msg.vcs_p4_submit);
    try testing.expect(bench.told("Submitting change 1234: 2 files (src/b.zig, src/c.zig); what you typed for the default changelist was dropped: this is change 1234's own description"));
    bench.applyText();
    try testing.expectEqualStrings("Fix the frame\nand its border", (try bench.description()).?);
}

test "vcs p4: e after a default submit that failed says what was typed is dropped" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try bench.open();
    const submit = try submitDefault(&bench, "Ship a.zig");
    try bench.answer(submit, 1, "");
    try bench.answerLists(pending_said, opened_said);
    bench.base.forgetRequests();
    try bench.onHeading("Change 1240");
    try bench.act(Msg.vcs_p4_describe);
    try testing.expect(bench.told("What you typed for the default changelist was dropped: this is change 1240's own description"));
    bench.applyText();
    try testing.expectEqualStrings("Docs", (try bench.description()).?);
}

test "vcs p4: a default submit that failed without numbering keeps what was typed, and s on the default changelist submits it" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try bench.open();
    const submit = try submitDefault(&bench, "Ship a.zig");
    try bench.answer(submit, 1, "");
    try testing.expect(bench.told(submit_failed));
    // Nothing numbered: the default changelist still holds a.zig.
    try bench.answerLists(pending_said, opened_said);
    bench.applyText();
    try testing.expectEqualStrings("Ship a.zig", (try bench.description()).?);
    try bench.act(Msg.vcs_p4_submit);
    try testing.expect(bench.told("Submitting the default changelist: 1 file (src/a.zig); the buffer holds what you typed: C-c C-c submits them"));
    bench.applyText();
    try testing.expectEqualStrings("Ship a.zig", (try bench.description()).?);
    const again = try submitDefault(&bench, "");
    try testing.expect(std.mem.indexOf(u8, again.input, "\tShip a.zig\n") != null);
}

/// The description's row, as far as a test reads it.
const KeptSubmit = struct { renumbered: *u8, file_count: *u32, file_paths: []const u8 };

fn keptSubmit(bench: *Bench) !Table.ReadView(KeptSubmit) {
    const table = bench.base.tables.findByName(Atom.from(p4_change.change_table_name)).?;
    var rows = table.readQuery(KeptSubmit);
    const row = rows.next() orelse return error.NoSuchRow;
    return row.view;
}

test "vcs p4: after a default submit given up, s on the default changelist holding other files keeps what was typed and says it was typed for other files" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try bench.open();
    const submit = try submitDefault(&bench, "Ship a.zig");
    try bench.base.markRunning(submit);
    try bench.act(Msg.vcs_p4_give_up);
    try testing.expect(bench.toldBeginning("Gave up waiting for p4 submit"));
    const given_up = try keptSubmit(&bench);
    try testing.expectEqual(@as(u8, 1), given_up.renumbered.*);
    try testing.expectEqualStrings("//depot/main/a.zig\n", given_up.file_paths);
    // The submit went through after all: a.zig is opened no more, and g.zig was opened since.
    const others = "... depotFile //depot/main/g.zig\n... clientFile /work/repo/src/g.zig\n... action edit\n... change default\n... type text\n\n" ++ comptime opened_said[std.mem.indexOf(u8, opened_said, "... depotFile //depot/main/b.zig").?..];
    bench.base.forgetRequests();
    try bench.act(Msg.vcs_p4_refresh);
    try bench.answerLists(pending_said, others);
    try bench.onHeading("Default changelist");
    try bench.act(Msg.vcs_p4_submit);
    try testing.expect(bench.told("Submitting the default changelist: 1 file (src/g.zig); the buffer holds what you typed for other files: change it, or C-c C-c submits these under it"));
    bench.applyText();
    try testing.expectEqualStrings("Ship a.zig", (try bench.description()).?);
    // That submit is begun anew: what `s` saw now is g.zig.
    const begun = try keptSubmit(&bench);
    try testing.expectEqual(@as(u8, 0), begun.renumbered.*);
    try testing.expectEqual(@as(u32, 1), begun.file_count.*);
    try testing.expectEqualStrings("//depot/main/g.zig\n", begun.file_paths);
}

test "vcs p4: N after a default submit that failed says what was typed is dropped, the new changelist beginning empty" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try bench.open();
    const submit = try submitDefault(&bench, "Ship a.zig");
    try bench.answer(submit, 1, "");
    try bench.answerLists(pending_said, opened_said);
    bench.base.forgetRequests();
    try bench.act(Msg.vcs_p4_new_change);
    try testing.expect(bench.told("What you typed for the default changelist was dropped: a new changelist begins empty"));
    bench.applyText();
    try testing.expectEqualStrings("", (try bench.description()).?);
}

test "vcs p4: after a default submit that failed, s on the changelist the server left already described as typed submits without saving" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try bench.open();
    const submit = try submitDefault(&bench, "Ship a.zig");
    try bench.answer(submit, 1, "");
    const numbered = pending_said ++ "... change 1261\n... time 1700000300\n... user bruno\n... client bruno_ws\n... status pending\n... desc Ship a.zig\n\n";
    const moved = "... depotFile //depot/main/a.zig\n... clientFile /work/repo/src/a.zig\n... action edit\n... change 1261\n... type text\n\n" ++ comptime opened_said[std.mem.indexOf(u8, opened_said, "... depotFile //depot/main/b.zig").?..];
    try bench.answerLists(numbered, moved);
    try bench.onHeading("Change 1261");
    try bench.act(Msg.vcs_p4_submit);
    try testing.expect(bench.told("Submitting change 1261: 1 file (src/a.zig); the buffer holds what you typed: C-c C-c submits"));
    bench.applyText();
    try testing.expectEqualStrings("Ship a.zig", (try bench.description()).?);
    bench.base.forgetRequests();
    try bench.act(p4_change.Msg.vcs_p4_message_finish);
    try bench.answerLists(numbered, moved);
    const by_number = try bench.job(.command);
    try testing.expectEqualStrings("p4\x1f-ztag\x1f-c\x1fbruno_ws\x1fsubmit\x1f-c\x1f1261", by_number.argv);
}

test "vcs p4: C-g during the default changelist's submit -i never sends it again from the buffer, which keeps what was typed" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try bench.open();
    const submit = try submitDefault(&bench, "Ship a.zig");
    try bench.base.markRunning(submit);
    try bench.act(Msg.vcs_p4_give_up);
    try testing.expect(bench.toldBeginning("Gave up waiting for p4 submit"));
    bench.base.forgetRequests();
    try bench.act(p4_change.Msg.vcs_p4_message_finish);
    try testing.expect(bench.told(refused_after_failure));
    var jobs: [8]runner.Job = undefined;
    try testing.expectEqual(@as(usize, 0), bench.queued(&jobs).len);
    try bench.act(Msg.vcs_p4_refresh);
    try bench.answerLists(pending_said, opened_said);
    try bench.act(Msg.vcs_p4_submit);
    bench.applyText();
    try testing.expectEqualStrings("Ship a.zig", (try bench.description()).?);
}

test "vcs p4: the submit's compare sees an action changed, not an order changed, and waits for the refresh after one in flight" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try bench.open();
    try bench.onHeading("Change 1234");
    try bench.act(Msg.vcs_p4_submit);
    bench.applyText();
    // c.zig reopened for delete in a terminal: the same paths, another action.
    const deleted = comptime blk: {
        @setEvalBranchQuota(100_000);
        var text: []const u8 = opened_said;
        const old = "... depotFile //depot/main/c.zig\n... clientFile /work/repo/src/c.zig\n... action add";
        const at = std.mem.indexOf(u8, text, old).?;
        text = text[0..at] ++ "... depotFile //depot/main/c.zig\n... clientFile /work/repo/src/c.zig\n... action delete" ++ text[at + old.len ..];
        break :blk text;
    };
    bench.base.forgetRequests();
    try bench.act(p4_change.Msg.vcs_p4_message_finish);
    try bench.answerLists(pending_said, deleted);
    try testing.expect(bench.toldBeginning("change 1234 changed since s"));
    try testing.expectError(error.NotQueued, bench.job(.command));
    bench.applyText();
    try testing.expect((try bench.description()) != null);
    // Taken again, then the files come back in another order: it submits.
    try bench.act(Msg.vcs_p4_submit);
    const reordered = comptime blk: {
        @setEvalBranchQuota(100_000);
        const b = std.mem.indexOf(u8, deleted, "... depotFile //depot/main/b.zig").?;
        const c = std.mem.indexOf(u8, deleted, "... depotFile //depot/main/c.zig").?;
        const d = std.mem.indexOf(u8, deleted, "... depotFile //depot/main/d.zig").?;
        break :blk deleted[0..b] ++ deleted[c..d] ++ deleted[b..c] ++ deleted[d..];
    };
    // A refresh in flight as C-c C-c is pressed: the compare waits for the one after it.
    bench.base.forgetRequests();
    try bench.act(Msg.vcs_p4_refresh);
    try bench.act(p4_change.Msg.vcs_p4_message_finish);
    try bench.answerLists(pending_said, opened_said);
    try testing.expectError(error.NotQueued, bench.job(.command));
    try bench.answerLists(pending_said, reordered);
    _ = try bench.job(.command);
}

test "vcs p4: the submit's compare sees a file's type changed" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try bench.open();
    try bench.onHeading("Change 1234");
    try bench.act(Msg.vcs_p4_submit);
    bench.applyText();
    // `reopen -t binary` on c.zig in a terminal: the same paths and actions, another type.
    const retyped = comptime blk: {
        @setEvalBranchQuota(100_000);
        const c = std.mem.indexOf(u8, opened_said, "... depotFile //depot/main/c.zig").?;
        const old = "... type text";
        const at = c + std.mem.indexOf(u8, opened_said[c..], old).?;
        break :blk opened_said[0..at] ++ "... type binary" ++ opened_said[at + old.len ..];
    };
    bench.base.forgetRequests();
    try bench.act(p4_change.Msg.vcs_p4_message_finish);
    try bench.answerLists(pending_said, retyped);
    try testing.expect(bench.toldBeginning("change 1234 changed since s"));
    try testing.expectError(error.NotQueued, bench.job(.command));
}

test "vcs p4: C-g while the submit's refresh runs keeps the buffer, and a project change ends the description" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try bench.open();
    try bench.onHeading("Change 1234");
    try bench.act(Msg.vcs_p4_submit);
    bench.applyText();
    bench.base.forgetRequests();
    try bench.act(p4_change.Msg.vcs_p4_message_finish);
    try bench.base.markRunning(try bench.job(.pending));
    try bench.act(Msg.vcs_p4_give_up);
    bench.run();
    try testing.expect(bench.toldBeginning("Gave up waiting for p4"));
    bench.applyText();
    try testing.expect((try bench.description()) != null);
    // Another project: the description is given up.
    const places = bench.base.tables.findByName(Atom.from(mesha.os.places_table_name)).?;
    try places.setString(.{ .row = 0, .generation = places.rowGeneration(0) }, "working_directory", "/elsewhere");
    try bench.act(Msg.vcs_p4_refresh);
    bench.run();
    try testing.expect(bench.told("The workspace changed; the description was given up"));
}

test "vcs p4: a workspace name vcs-p4 does not pass is said as such" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try bench.act(Msg.vcs_p4_status);
    const info = try bench.job(.info);
    bench.base.forgetRequests();
    try bench.answer(info, 0, "... userName bruno\n... clientName -odd\n... clientRoot /work/repo\n\n");
    try testing.expect(std.mem.startsWith(u8, bench.value("vcs-p4.note").?, "p4 info names the workspace -odd, a name vcs-p4 does not pass"));
}

test "vcs p4: a file opened after s is not submitted: C-c C-c refuses, and a default changelist's form listing another file too" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try bench.open();
    try bench.onHeading("Change 1234");
    try bench.act(Msg.vcs_p4_submit);
    bench.applyText();
    bench.base.forgetRequests();
    try bench.act(p4_change.Msg.vcs_p4_message_finish);
    const more = opened_said ++ "... depotFile //depot/main/g.zig\n... clientFile /work/repo/g.zig\n... action edit\n... change 1234\n... type text\n\n";
    try bench.answerLists(pending_said, more);
    try testing.expect(bench.told("change 1234 changed since s (it had 2 files, it has 3), so nothing was submitted: s asks again; the description is kept"));
    try testing.expectError(error.NotQueued, bench.job(.command));
    bench.applyText();
    try testing.expect((try bench.description()) != null);
    // The default changelist: the lists agree, but the form lists a file opened meanwhile.
    try bench.act(p4_change.Msg.vcs_p4_message_cancel);
    try bench.onHeading("Default changelist");
    try bench.act(Msg.vcs_p4_submit);
    bench.applyText();
    bench.write("Ship a.zig");
    bench.base.forgetRequests();
    try bench.act(p4_change.Msg.vcs_p4_message_finish);
    try bench.answerLists(pending_said, opened_said);
    const form_job = try bench.job(.command);
    bench.base.forgetRequests();
    try bench.answer(form_job, 0, "Change:\tnew\n\nDescription:\n\t<enter description here>\n\nFiles:\n\t//depot/main/a.zig\t# edit\n\t//depot/main/h.zig\t# add\n");
    try testing.expectError(error.NotQueued, bench.job(.command));
    try testing.expect(bench.toldBeginning("the default changelist changed since s"));
    bench.applyText();
    try testing.expect((try bench.description()) != null);
}

test "vcs p4: N makes an empty changelist, the default one's files left where they are" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try bench.open();
    try bench.act(Msg.vcs_p4_new_change);
    bench.applyText();
    bench.write("Next thing");
    bench.base.forgetRequests();
    try bench.act(p4_change.Msg.vcs_p4_message_finish);
    const form_job = try bench.job(.command);
    try testing.expectEqualStrings("p4\x1f-c\x1fbruno_ws\x1fchange\x1f-o", form_job.argv);
    bench.base.forgetRequests();
    try bench.answer(form_job, 0, "Change:\tnew\n\nClient:\tbruno_ws\n\nStatus:\tnew\n\nDescription:\n\t<enter description here>\n\nFiles:\n\t//depot/main/a.zig\t# edit\n");
    const save = try bench.job(.command);
    try testing.expectEqualStrings("p4\x1f-c\x1fbruno_ws\x1fchange\x1f-i", save.argv);
    try testing.expectEqualStrings("Change:\tnew\n\nClient:\tbruno_ws\n\nStatus:\tnew\n\nDescription:\n\tNext thing\n\n", save.input);
    bench.base.forgetRequests();
    try bench.answer(save, 0, "Change 1260 created.\n");
    try testing.expect(bench.told("Change 1260 made"));
}

test "vcs p4: m on a file reopens it in the chosen changelist, and on a changelist all its files in one program" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try bench.open();
    try bench.onFile("//depot/main/a.zig", "default");
    bench.base.forgetRequests();
    try bench.act(Msg.vcs_p4_move);
    // The prompt lists the panel's changelists, not the one the file is in.
    const prompt = bench.base.dialog().?;
    try testing.expectEqual(@as(usize, 3), prompt.completions.entries.len);
    try testing.expectEqualStrings("1240", prompt.completions.entries[1].key);
    try bench.choose("1240  Docs");
    const reopen = try bench.job(.command);
    try testing.expectEqualStrings("p4\x1f-ztag\x1f-c\x1fbruno_ws\x1f-x\x1f-\x1freopen\x1f-c\x1f1240", reopen.argv);
    try testing.expectEqualStrings("//depot/main/a.zig\n", reopen.input);
    // On 1234's heading: both its files, one program, to the default changelist.
    try bench.onHeading("Change 1234");
    bench.base.forgetRequests();
    try bench.act(Msg.vcs_p4_move);
    try bench.choose("default");
    var jobs: [8]runner.Job = undefined;
    const queued = bench.queued(&jobs);
    try testing.expectEqual(@as(usize, 1), queued.len);
    try testing.expectEqualStrings("p4\x1f-ztag\x1f-c\x1fbruno_ws\x1f-x\x1f-\x1freopen\x1f-c\x1fdefault", queued[0].argv);
    try testing.expectEqualStrings("//depot/main/b.zig\n//depot/main/c.zig\n", queued[0].input);
}

test "vcs p4: k on a changelist's heading asks first and reverts its files in one program; a change meanwhile refuses" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try bench.open();
    try bench.onHeading("Change 1234");
    bench.base.forgetRequests();
    try bench.act(Msg.vcs_p4_revert);
    const dialog = bench.base.dialog().?;
    try testing.expectEqualStrings("Revert the 2 files of change 1234?", dialog.completions.title);
    try testing.expect(std.mem.indexOf(u8, dialog.completions.body, "opened for add is left in the workspace") != null);
    var jobs: [8]runner.Job = undefined;
    try testing.expectEqual(@as(usize, 0), bench.queued(&jobs).len);
    try bench.choose("Revert");
    const revert = try bench.job(.command);
    try testing.expectEqualStrings("p4\x1f-ztag\x1f-c\x1fbruno_ws\x1f-x\x1f-\x1frevert", revert.argv);
    try testing.expectEqualStrings("//depot/main/b.zig\n//depot/main/c.zig\n", revert.input);
    // Asked again, then a refresh in which 1234 gained a file: the yes runs nothing.
    bench.base.forgetRequests();
    try bench.answer(revert, 0, "");
    try bench.answerLists(pending_said, opened_said);
    try bench.onHeading("Change 1234");
    try bench.act(Msg.vcs_p4_revert);
    const asked = bench.base.dialog().?;
    bench.base.dialogs().reset();
    const more = opened_said ++ "... depotFile //depot/main/g.zig\n... clientFile /work/repo/g.zig\n... action edit\n... change 1234\n... type text\n\n";
    try bench.refreshWith(pending_said, more);
    bench.base.forgetRequests();
    const chosen = asked.completions.entries[0];
    const payload = try plugin.editor_api.eventPayload(bench.base.arena.allocator(), .{ .kind = .completed, .completion = chosen, .query = "" });
    try sequencer.deliverMessage(&bench.base.tables, asked.reply.inbox, asked.reply.tag, asked.reply.user_data.bytes, payload);
    bench.run();
    try testing.expect(bench.told("It changed meanwhile; k asks again"));
    try testing.expectEqual(@as(usize, 0), bench.queued(&jobs).len);
}

test "vcs p4: d deletes an empty changelist and is refused for one with files or shelved files" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try bench.open();
    try bench.onHeading("Change 1234");
    bench.base.forgetRequests();
    try bench.act(Msg.vcs_p4_delete_change);
    try testing.expect(bench.told("Change 1234 has 2 files: m moves them, k reverts them"));
    try bench.onHeading("Change 1250");
    try bench.act(Msg.vcs_p4_delete_change);
    try testing.expect(bench.told("Change 1250 has shelved files: z d deletes the shelf first"));
    var jobs: [8]runner.Job = undefined;
    try testing.expectEqual(@as(usize, 0), bench.queued(&jobs).len);
    // Without its shelf it is empty: `change -d`.
    const unshelved = "... change 1250\n... time 1700000200\n... user bruno\n... client bruno_ws\n... status pending\n... desc Nothing yet\n\n";
    bench.base.forgetRequests();
    try bench.act(Msg.vcs_p4_refresh);
    var lists: [4]runner.Job = undefined;
    for (&lists, [_]p4_status.Purpose{ .pending, .shelved_changes, .opened, .submitted }) |*slot, purpose| slot.* = try bench.job(purpose);
    bench.base.forgetRequests();
    try bench.answer(lists[0], 0, pending_said ++ unshelved);
    try bench.answer(lists[1], 0, "");
    try bench.answer(lists[2], 0, opened_said);
    try bench.answer(lists[3], 0, submitted_said);
    try bench.onHeading("Change 1250");
    try bench.act(Msg.vcs_p4_delete_change);
    const delete = try bench.job(.command);
    try testing.expectEqualStrings("p4\x1f-ztag\x1f-c\x1fbruno_ws\x1fchange\x1f-d\x1f1250", delete.argv);
}

test "vcs p4: RET on a file asks for its changelist's diff once and shows that file" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try bench.open();
    try bench.onFile("//depot/main/b.zig", "1234");
    bench.base.forgetRequests();
    try bench.act(Msg.vcs_p4_visit);
    const diff = try bench.job(.diff);
    // Only the file opened for edit is compared: `c.zig` is opened for add.
    try testing.expectEqualStrings("p4\x1f-c\x1fbruno_ws\x1f-x\x1f-\x1fdiff\x1f-du", diff.argv);
    try testing.expectEqualStrings("//depot/main/b.zig\n", diff.input);
    try testing.expectEqualStrings(p4.internal_diff_environment, diff.environment);
    bench.base.forgetRequests();
    try bench.answer(diff, 0, "==== //depot/main/b.zig#3 - /work/repo/src/b.zig ====\n@@ -1,2 +1,2 @@\n one\n-two\n+TWO\n");
    const sources = p4_diff.sourcesOf(&bench.base.tables).?;
    const built = try p4_diff.build(bench.base.arena.allocator(), sources);
    var hunks: u32 = 0;
    for (built.lines) |line| {
        if (line.kind == @intFromEnum(p4_diff.LineKind.hunk)) hunks += 1;
    }
    try testing.expectEqual(@as(u32, 1), hunks);
    try testing.expectEqualStrings("/work/repo/src/b.zig", built.local_path);
    // The file opened for add, from the same changelist: nothing more asked, its state said.
    try bench.onFile("//depot/main/c.zig", "1234");
    try bench.act(Msg.vcs_p4_visit);
    var jobs: [8]runner.Job = undefined;
    try testing.expectEqual(@as(usize, 0), bench.queued(&jobs).len);
    const added = try p4_diff.build(bench.base.arena.allocator(), p4_diff.sourcesOf(&bench.base.tables).?);
    try testing.expect(std.mem.startsWith(u8, added.lines[0].text, "Opened for add: there is no revision"));
    // `s` in the diff panel: Perforce has no index.
    try bench.act(p4_diff.Msg.vcs_p4_diff_no_index);
    try testing.expect(bench.told("Perforce has no index: s in the changelists panel submits"));
}

test "vcs p4: a diff whose body is another program's output is shown as text, with the note why" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try bench.open();
    try bench.onFile("//depot/main/b.zig", "1234");
    bench.base.forgetRequests();
    try bench.act(Msg.vcs_p4_visit);
    const diff = try bench.job(.diff);
    bench.base.forgetRequests();
    try bench.answer(diff, 0, "==== //depot/main/b.zig#3 - /work/repo/src/b.zig ====\n2c2\n< two\n---\n> TWO\n");
    const built = try p4_diff.build(bench.base.arena.allocator(), p4_diff.sourcesOf(&bench.base.tables).?);
    try testing.expect(std.mem.startsWith(u8, built.lines[0].text, "Not a unified diff: P4DIFF or DIFF"));
    try testing.expectEqualStrings("2c2", built.lines[1].text);
    try testing.expectEqualStrings("> TWO", built.lines[4].text);
}

test "vcs p4: the cursor stays on the same file in the same changelist across a refresh, and lands on the next changelist when its own was submitted" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try bench.open();
    try bench.onFile("//depot/main/c.zig", "1234");
    // The files come back in another order: the row `c.zig` was on now holds `b.zig`.
    const reordered =
        "... depotFile //depot/main/c.zig\n... clientFile /work/repo/src/c.zig\n... action add\n... change 1234\n... type text\n\n" ++
        "... depotFile //depot/main/b.zig\n... clientFile /work/repo/src/b.zig\n... action edit\n... change 1234\n... type text\n\n" ++
        "... depotFile //depot/main/d.zig\n... clientFile /work/repo/src/d.zig\n... action integrate\n... change 1240\n... type text\n\n";
    try bench.refreshWith(pending_said, reordered);
    const at = try bench.at();
    try testing.expectEqualStrings("//depot/main/c.zig", at.row.table.getRow(at.row.row, p4_status.FileRow).?.depot_path);
    try testing.expectEqualStrings("1234", at.row.group.?.key_text);
    // 1234 submitted: gone with its files; the cursor lands on 1240, the next changelist.
    const without_1234 = "... change 1240\n... time 1700000100\n... user bruno\n... client bruno_ws\n... status pending\n... desc Docs\n\n";
    const only_1240 = "... depotFile //depot/main/d.zig\n... clientFile /work/repo/src/d.zig\n... action integrate\n... change 1240\n... type text\n\n";
    try bench.refreshWith(without_1234, only_1240);
    const landed = try bench.at();
    try testing.expectEqualStrings("1240", landed.group.key_text);
}

test "vcs p4: no refresh runs on a timer or on the panel taking the focus unless the setting asks for one" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try bench.open();
    // No timer was asked: the page has no #+REFRESH:, the setting is absent.
    bench.run();
    try testing.expectEqual(@as(?status_test.TimerAsk, null), timerAsked(&bench));
    // The panel taking the focus, and a buffer saved, refresh nothing.
    bench.base.forgetRequests();
    const events = plugin.panels.Events.of(&bench.base.tables, plugin.panels.events_table_name);
    events.publish(.{ .unfocused = Atom.from("vcs_p4_test_text_panel") });
    events.publish(.{ .focused = p4_status.panel });
    const saves = text_editor.Events.of(&bench.base.tables, text_editor.events_table_name);
    saves.publish(.{ .changed = .{ .buffer = Atom.from("vcs_p4_test_buffer"), .revision = 1, .serial = 1, .modified = false, .saved = true } });
    bench.run();
    var jobs: [8]runner.Job = undefined;
    try testing.expectEqual(@as(usize, 0), bench.queued(&jobs).len);
    // The setting asks for one every 30 seconds: a wake is asked, and its message refreshes.
    try setRefreshSeconds(&bench, 30);
    bench.run();
    try testing.expectEqual(@as(?status_test.TimerAsk, .{ .wake = 30 }), timerAsked(&bench));
    const fired: mesha.time.WakeMsg = .{ .after = 30 };
    try sequencer.deliverMessage(&bench.base.tables, sequencer.inboxOf(p4_status.system()), Atom.from(Msg.vcs_p4_timer), &.{}, std.mem.asBytes(&fired));
    bench.run();
    _ = try bench.job(.pending);
    // 0 turns it off again.
    try setRefreshSeconds(&bench, 0);
    bench.run();
    try testing.expectEqual(@as(?status_test.TimerAsk, .cancel), timerAsked(&bench));
}

/// The setting `vcs_p4_refresh_seconds`, set to `seconds`.
fn setRefreshSeconds(bench: *Bench, seconds: u32) !void {
    const settings = bench.base.tables.findByName(Atom.from(mesha.keybinds.editor_settings_name)).?;
    var rows = settings.rows();
    const row = rows.next().?;
    try settings.writeFieldSingle(u32, row, mesha.keybinds.vcs_p4_refresh_field, seconds);
}

/// What vcs-p4 asked of the time system since this was last called, the last request.
fn timerAsked(bench: *Bench) ?status_test.TimerAsk {
    const commands = bench.base.tables.findByName(Atom.from(mesha.time.commands_table_name)).?;
    defer commands.clear();
    var last: ?status_test.TimerAsk = null;
    var rows = commands.readQuery(struct { op: *mesha.time.CommandOp, wake: *mesha.time.Wake });
    while (rows.next()) |row| {
        const wake = row.view.wake.*;
        if (wake.inbox != sequencer.inboxOf(p4_status.system()) or wake.tag != Atom.from(Msg.vcs_p4_timer)) continue;
        last = switch (row.view.op.*) {
            .wake => .{ .wake = wake.after },
            .cancel_wake => .cancel,
            .animate, .cancel_animation => last,
        };
    }
    return last;
}

/// The menu presented since the requests were last forgotten answered with `id`, and the
/// system's run.
fn chooseInMenu(bench: *Bench, id: u32) !void {
    const requests = transient.Requests.of(&bench.base.memory, &bench.base.tables, transient.requests_table_name);
    var sent: [8]transient.Request = undefined;
    const waiting = requests.peek(&sent);
    if (waiting.len == 0) return error.NoMenu;
    const presented = waiting[waiting.len - 1].present;
    requests.reset();
    const chosen: transient.Chosen = .{ .id = id, .cancelled = 0, .state = .{} };
    try sequencer.deliverMessage(&bench.base.tables, presented.reply.inbox, presented.reply.tag, presented.reply.user_data.bytes, std.mem.asBytes(&chosen));
    bench.run();
}

test "vcs p4: the menu of menus refuses in the process log and the history what acts on the hidden changelists' cursor" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try bench.open();
    // The changelists' cursor, about to be hidden, is on an empty changelist.
    try bench.onHeading("Change 1250");
    try bench.act(Msg.vcs_p4_process_log);
    var storage: [8]runner.Job = undefined;
    const commands = [_]p4_status.MenuCommand{ .submit, .describe, .move, .revert, .revert_unchanged, .delete_change, .shelve, .open_file, .reconcile };
    for (commands) |command| {
        bench.base.forgetRequests();
        try bench.act(Msg.vcs_p4_menu);
        try chooseInMenu(&bench, @intFromEnum(command));
        try testing.expect(bench.told("Not in the process log: q goes back to the changelists"));
        try testing.expectEqual(@as(usize, 0), bench.queued(&storage).len);
        try testing.expectEqual(@as(?Bench.Presented, null), bench.base.dialog());
    }
    // In the history, the same in its own words.
    try bench.act(Msg.vcs_p4_quit);
    try bench.act(@import("p4_history.zig").Msg.vcs_p4_history);
    bench.base.forgetRequests();
    try bench.act(Msg.vcs_p4_menu);
    try chooseInMenu(&bench, @intFromEnum(p4_status.MenuCommand.delete_change));
    try testing.expect(bench.told("Not in the history: q goes back to the changelists"));
    try testing.expectEqual(@as(usize, 0), bench.queued(&storage).len);
}

test "vcs p4: the shelve, sync and resolve commands, each one program, the default changelist refused a shelf" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try bench.open();
    try bench.onHeading("Default changelist");
    try bench.act(Msg.vcs_p4_shelve_menu);
    try testing.expect(bench.toldBeginning("The default changelist cannot be shelved by number"));
    try bench.onHeading("Change 1234");
    bench.base.forgetRequests();
    try bench.act(Msg.vcs_p4_shelve_menu);
    try chooseInMenu(&bench, @intFromEnum(p4_status.ShelveItem.replace));
    const shelve = try bench.job(.command);
    try testing.expectEqualStrings("p4\x1f-ztag\x1f-c\x1fbruno_ws\x1fshelve\x1f-r\x1f-c\x1f1234", shelve.argv);
    try testing.expectEqual(runner.Order.alone, shelve.order);
    // Deleting the shelf asks first.
    bench.base.forgetRequests();
    try bench.act(Msg.vcs_p4_shelve_menu);
    try chooseInMenu(&bench, @intFromEnum(p4_status.ShelveItem.discard));
    var jobs: [8]runner.Job = undefined;
    try testing.expectEqual(@as(usize, 0), bench.queued(&jobs).len);
    try bench.choose("Delete shelf");
    try testing.expectEqualStrings("p4\x1f-ztag\x1f-c\x1fbruno_ws\x1fshelve\x1f-d\x1f-c\x1f1234", (try bench.job(.command)).argv);
    // Unshelving goes into the same changelist.
    bench.base.forgetRequests();
    try bench.act(Msg.vcs_p4_shelve_menu);
    try chooseInMenu(&bench, @intFromEnum(p4_status.ShelveItem.unshelve));
    try testing.expectEqualStrings("p4\x1f-ztag\x1f-c\x1fbruno_ws\x1funshelve\x1f-s\x1f1234\x1f-c\x1f1234", (try bench.job(.command)).argv);
    // Sync's preview, and resolve.
    bench.base.forgetRequests();
    try bench.act(Msg.vcs_p4_sync_menu);
    try chooseInMenu(&bench, @intFromEnum(p4_status.SyncItem.preview));
    try testing.expectEqualStrings("p4\x1f-ztag\x1f-c\x1fbruno_ws\x1fsync\x1f-n", (try bench.job(.command)).argv);
    bench.base.forgetRequests();
    try bench.act(Msg.vcs_p4_resolve);
    try testing.expectEqualStrings("p4\x1f-ztag\x1f-c\x1fbruno_ws\x1fresolve\x1f-am", (try bench.job(.command)).argv);
}

test "vcs p4: r shows what reconcile -n found, then a yes opens it into the changelist under the cursor" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try bench.open();
    try bench.onHeading("Change 1240");
    bench.base.forgetRequests();
    try bench.act(Msg.vcs_p4_reconcile);
    const preview = try bench.job(.command);
    try testing.expectEqualStrings("p4\x1f-ztag\x1f-c\x1fbruno_ws\x1freconcile\x1f-n\x1f/work/repo/sub/...", preview.argv);
    bench.base.forgetRequests();
    try bench.answer(preview, 0, "... depotFile //depot/main/new.zig\n... action add\n");
    const dialog = bench.base.dialog().?;
    try testing.expectEqualStrings("Open what p4 reconcile found into change 1240?", dialog.completions.title);
    try bench.choose("Open");
    const opened = try bench.job(.command);
    try testing.expectEqualStrings("p4\x1f-ztag\x1f-c\x1fbruno_ws\x1freconcile\x1f-c\x1f1240\x1f/work/repo/sub/...", opened.argv);
}

test "vcs p4: l runs the workspace's history, a query typed replaces it, and one choosing the output form is refused" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try bench.open();
    bench.base.forgetRequests();
    try bench.act(@import("p4_history.zig").Msg.vcs_p4_history);
    const history = try bench.job(.history);
    try testing.expectEqualStrings("p4\x1f-ztag\x1f-c\x1fbruno_ws\x1fchanges\x1f-l\x1f-s\x1fsubmitted\x1f-m\x1f100\x1f//bruno_ws/...", history.argv);
    try testing.expectEqualStrings("-s submitted -m 100 //bruno_ws/...", bench.value("vcs-p4.history-query").?);
    bench.base.forgetRequests();
    try bench.answer(history, 0, submitted_said);
    try testing.expectEqualStrings("", bench.value("vcs-p4.history-note").?);
    // A query typed: `-u 'ana b'` stays one argument.
    try bench.act(@import("p4_history.zig").Msg.vcs_p4_history_edit);
    const prompt = bench.base.dialog().?;
    const payload = try plugin.editor_api.eventPayload(bench.base.arena.allocator(), .{ .kind = .completed, .completion = .{ .label = "" }, .query = "-m 5 -u 'ana b'" });
    bench.base.dialogs().reset();
    try sequencer.deliverMessage(&bench.base.tables, prompt.reply.inbox, prompt.reply.tag, prompt.reply.user_data.bytes, payload);
    bench.run();
    try testing.expectEqualStrings("p4\x1f-ztag\x1f-c\x1fbruno_ws\x1fchanges\x1f-l\x1f-m\x1f5\x1f-u\x1fana b", (try bench.job(.history)).argv);
    // `-G` would change the output form: told, nothing run, the prompt open again holding it.
    bench.base.forgetRequests();
    try bench.act(@import("p4_history.zig").Msg.vcs_p4_history_edit);
    const again = bench.base.dialog().?;
    const refused = try plugin.editor_api.eventPayload(bench.base.arena.allocator(), .{ .kind = .completed, .completion = .{ .label = "" }, .query = "-G -m 5" });
    bench.base.dialogs().reset();
    try sequencer.deliverMessage(&bench.base.tables, again.reply.inbox, again.reply.tag, again.reply.user_data.bytes, refused);
    bench.run();
    try testing.expect(bench.toldBeginning("p4 changes has no -z, -G or -M option"));
    var jobs: [8]runner.Job = undefined;
    try testing.expectEqual(@as(usize, 0), bench.queued(&jobs).len);
    try testing.expectEqualStrings("-G -m 5", bench.base.dialog().?.completions.initial_query);
}

/// `g`, its lists answered as given with the action `tag` in the run that takes the last of
/// them: a key pressed as an answer moved the rows under it.
fn refreshWithKeyInSameRun(bench: *Bench, pending: []const u8, opened: []const u8, tag: Msg) !void {
    bench.base.forgetRequests();
    try bench.act(Msg.vcs_p4_refresh);
    const purposes = [_]p4_status.Purpose{ .pending, .shelved_changes, .opened, .submitted };
    const saids = [_][]const u8{ pending, shelved_said, opened, submitted_said };
    var jobs: [4]runner.Job = undefined;
    for (&jobs, purposes) |*slot, purpose| slot.* = try bench.job(purpose);
    bench.base.forgetRequests();
    for (jobs[0..3], saids[0..3]) |list_job, said| try bench.answer(list_job, 0, said);
    _ = try bench.base.finish(jobs[3], 0, saids[3], "");
    bench.run();
    const described = try bench.job(.describe_shelved);
    bench.base.forgetRequests();
    _ = try bench.base.finish(described, 0, described_said, "");
    const inbox = sequencer.inboxOf(p4_status.system());
    try sequencer.deliverMessage(&bench.base.tables, inbox, Atom.from(tag), &.{}, &.{});
    bench.run();
}

test "vcs p4: a key in the run of an answer that took the cursor's file or changelist away acts on nothing" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try bench.open();
    // The cursor on c.zig of 1234; the answer has c.zig reverted elsewhere: `m` in that run.
    try bench.onFile("//depot/main/c.zig", "1234");
    const without_c = comptime blk: {
        const start = std.mem.indexOf(u8, opened_said, "... depotFile //depot/main/c.zig").?;
        const end = std.mem.indexOf(u8, opened_said, "... depotFile //depot/main/d.zig").?;
        break :blk opened_said[0..start] ++ opened_said[end..];
    };
    try refreshWithKeyInSameRun(&bench, pending_said, without_c, Msg.vcs_p4_move);
    try testing.expect(bench.told("The changelists changed under the cursor"));
    try testing.expectEqual(@as(?Bench.Presented, null), bench.base.dialog());
    // The cursor on 1240's heading; the answer has 1240 gone: `k` in that run.
    try bench.onHeading("Change 1240");
    const without_1240 = pending_said[0..std.mem.indexOf(u8, pending_said, "... change 1240").?];
    try refreshWithKeyInSameRun(&bench, without_1240, without_c, Msg.vcs_p4_revert);
    try testing.expect(bench.told("The changelists changed under the cursor"));
    try testing.expectEqual(@as(?Bench.Presented, null), bench.base.dialog());
}

test "vcs p4: m's prompt says what moves, a typed answer must be a changelist listed, and files gone meanwhile refuse" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try bench.open();
    try bench.onFile("//depot/main/a.zig", "default");
    bench.base.forgetRequests();
    try bench.act(Msg.vcs_p4_move);
    try testing.expectEqualStrings("Move src/a.zig to", bench.base.dialog().?.completions.title);
    try bench.onHeading("Change 1234");
    bench.base.forgetRequests();
    try bench.act(Msg.vcs_p4_move);
    const prompt = bench.base.dialog().?;
    try testing.expectEqualStrings("Move the 2 files of change 1234 to", prompt.completions.title);
    // Typed: a number not listed is refused, the prompt opened again holding it.
    bench.base.dialogs().reset();
    const typed = try plugin.editor_api.eventPayload(bench.base.arena.allocator(), .{ .kind = .completed, .completion = .{ .label = "" }, .query = "999" });
    try sequencer.deliverMessage(&bench.base.tables, prompt.reply.inbox, prompt.reply.tag, prompt.reply.user_data.bytes, typed);
    bench.run();
    try testing.expect(bench.told("Change 999 is no pending changelist of this workspace listed here"));
    try testing.expectEqualStrings("999", bench.base.dialog().?.completions.initial_query);
    // A file of 1234 reverted elsewhere before the answer: nothing moves.
    const reopened = bench.base.dialog().?;
    bench.base.dialogs().reset();
    const without_c = comptime blk: {
        const start = std.mem.indexOf(u8, opened_said, "... depotFile //depot/main/c.zig").?;
        const end = std.mem.indexOf(u8, opened_said, "... depotFile //depot/main/d.zig").?;
        break :blk opened_said[0..start] ++ opened_said[end..];
    };
    try bench.refreshWith(pending_said, without_c);
    bench.base.forgetRequests();
    const chosen = try plugin.editor_api.eventPayload(bench.base.arena.allocator(), .{ .kind = .completed, .completion = .{ .label = "default", .key = "default" }, .query = "" });
    try sequencer.deliverMessage(&bench.base.tables, reopened.reply.inbox, reopened.reply.tag, reopened.reply.user_data.bytes, chosen);
    bench.run();
    try testing.expect(bench.told("It changed meanwhile; m asks again"));
    try testing.expectError(error.NotQueued, bench.job(.command));
}

test "vcs p4: K reverts the unchanged files of a changelist, its files named on the input, after a dialog" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try bench.open();
    try bench.onHeading("Default changelist");
    bench.base.forgetRequests();
    try bench.act(Msg.vcs_p4_revert_unchanged);
    try testing.expectEqualStrings("Revert the unchanged files of the default changelist?", bench.base.dialog().?.completions.title);
    try bench.choose("Revert unchanged");
    const revert = try bench.job(.command);
    try testing.expectEqualStrings("p4\x1f-ztag\x1f-c\x1fbruno_ws\x1f-x\x1f-\x1frevert\x1f-a", revert.argv);
    try testing.expectEqualStrings("//depot/main/a.zig\n", revert.input);
}

test "vcs p4: k on one file asks first and reverts that file alone" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try bench.open();
    try bench.onFile("//depot/main/b.zig", "1234");
    bench.base.forgetRequests();
    try bench.act(Msg.vcs_p4_revert);
    try testing.expectEqualStrings("Revert src/b.zig?", bench.base.dialog().?.completions.title);
    try bench.choose("Revert");
    try testing.expectEqualStrings("//depot/main/b.zig\n", (try bench.job(.command)).input);
}

test "vcs p4: e saves a changelist's description with change -o and change -i" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try bench.open();
    try bench.onHeading("Change 1240");
    try bench.act(Msg.vcs_p4_describe);
    bench.applyText();
    try testing.expectEqualStrings("Docs", (try bench.description()).?);
    bench.write("Docs, rewritten");
    bench.base.forgetRequests();
    try bench.act(p4_change.Msg.vcs_p4_message_finish);
    const form_job = try bench.job(.command);
    try testing.expectEqualStrings("p4\x1f-c\x1fbruno_ws\x1fchange\x1f-o\x1f1240", form_job.argv);
    bench.base.forgetRequests();
    try bench.answer(form_job, 0, "Change:\t1240\n\nDescription:\n\tDocs\n\nFiles:\n\t//depot/main/d.zig\t# integrate\n");
    const save = try bench.job(.command);
    try testing.expectEqualStrings("Change:\t1240\n\nDescription:\n\tDocs, rewritten\n\nFiles:\n\t//depot/main/d.zig\t# integrate\n", save.input);
    bench.base.forgetRequests();
    try bench.answer(save, 0, "Change 1240 updated.\n");
    try testing.expect(bench.told("Saved the description of change 1240"));
    // The default changelist has none.
    try bench.onHeading("Default changelist");
    try bench.act(Msg.vcs_p4_describe);
    try testing.expect(bench.toldBeginning("The default changelist has no description"));
}

test "vcs p4: a's menu opens the visited file for edit or add (encoded or literal), a delete after a dialog" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    // The visited file: a text window on a file `new@1.zig` opened by the text editor, the
    // newest text window in the focus history.
    var directory = testing.tmpDir(.{});
    defer directory.cleanup();
    try directory.dir.writeFile(testing.io, .{ .sub_path = "new@1.zig", .data = "const a = 1;\n" });
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const directory_length = try directory.dir.realPath(testing.io, &path_buffer);
    const path = try std.fmt.allocPrint(bench.base.arena.allocator(), "{s}/new@1.zig", .{path_buffer[0..directory_length]});
    const reply = sequencer.ReplyTo.of(p4_status.system(), Atom.from("vcs_p4_test_opened"));
    bench.editors.apply(&bench.base.tables, .{ .open = .{ .path = path, .reply = reply } });
    bench.editors.publish(&bench.base.tables);
    const buffers = bench.base.tables.findByName(Atom.from(text_editor.buffers_table_name)).?;
    var buffer_rows = buffers.readQuery(text_editor.BufferEntry);
    const buffer = while (buffer_rows.next()) |row| {
        if (std.mem.eql(u8, row.view.path, path)) break row.view.buffer.*;
    } else return error.NotOpened;
    const windows = bench.base.tables.findByName(Atom.from(text_panel.table_name)).?;
    const window = Atom.from("text_panel_00");
    // The first text window's row shows the visited buffer.
    var window_rows = windows.query(text_panel.WindowBufferRow);
    var shown = false;
    while (window_rows.next()) |row| {
        if (row.view.panel.* != window) continue;
        row.view.buffer.* = buffer;
        shown = true;
    }
    if (!shown) _ = try windows.tryInsert(.{ .panel = window, .buffer = buffer });
    const history = bench.base.tables.findByName(Atom.from(mesha.panels.focus_history_table_name)).?;
    _ = try history.tryInsert(.{ .panel = window });
    try bench.open();
    try bench.onHeading("Change 1240");
    const items = [_]struct { item: p4_status.OpenItem, argv: []const u8, input: []const u8 }{
        .{ .item = .edit, .argv = "p4\x1f-ztag\x1f-c\x1fbruno_ws\x1f-x\x1f-\x1fedit\x1f-c\x1f1240", .input = try std.mem.replaceOwned(u8, bench.base.arena.allocator(), path, "@", "%40") },
        .{ .item = .add, .argv = "p4\x1f-ztag\x1f-c\x1fbruno_ws\x1f-x\x1f-\x1fadd\x1f-f\x1f-c\x1f1240", .input = path },
    };
    for (items) |case| {
        bench.base.forgetRequests();
        try bench.act(Msg.vcs_p4_open_menu);
        try chooseInMenu(&bench, @intFromEnum(case.item));
        const opened = try bench.job(.command);
        try testing.expectEqualStrings(case.argv, opened.argv);
        try testing.expectEqualStrings(case.input, std.mem.trimEnd(u8, opened.input, "\n"));
    }
    bench.base.forgetRequests();
    try bench.act(Msg.vcs_p4_open_menu);
    try chooseInMenu(&bench, @intFromEnum(p4_status.OpenItem.delete));
    try testing.expectError(error.NotQueued, bench.job(.command));
    try bench.choose("Delete");
    try testing.expectEqualStrings("p4\x1f-ztag\x1f-c\x1fbruno_ws\x1f-x\x1f-\x1fdelete\x1f-c\x1f1240", (try bench.job(.command)).argv);
}

test "vcs p4: commands are refused while the lists could not be read" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try bench.open();
    bench.base.forgetRequests();
    try bench.act(Msg.vcs_p4_refresh);
    var jobs: [4]runner.Job = undefined;
    for (&jobs, [_]p4_status.Purpose{ .pending, .shelved_changes, .opened, .submitted }) |*slot, purpose| slot.* = try bench.job(purpose);
    bench.base.forgetRequests();
    for (jobs) |list| try bench.answer(list, 1, "p4: some error\n");
    try bench.onHeading("Change 1234");
    bench.base.forgetRequests();
    try bench.act(Msg.vcs_p4_revert);
    try testing.expect(bench.told("The lists could not be read (see the note): g reads them again"));
    try testing.expectEqual(@as(?Bench.Presented, null), bench.base.dialog());
}

/// The last refresh counted `seen` opened files, more than the fixtures list: those past what the
/// panel keeps.
fn setOpenedSeen(bench: *Bench, seen: u32) void {
    const state = bench.base.tables.findByName(Atom.from(p4_status.state_table_name)).?;
    const row = state.getRow(.{ .row = 0, .generation = state.rowGeneration(0) }, struct { opened_seen: *u32 }).?;
    row.opened_seen.* = seen;
}

test "vcs p4: s, K, and k and m on a changelist are refused while some opened files are not listed" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try bench.open();
    // Four files listed of ten opened.
    setOpenedSeen(&bench, 10);
    const refused = "Not every opened file is listed (6 are not): do this from a terminal";
    var storage: [8]runner.Job = undefined;
    for ([_]Msg{ .vcs_p4_submit, .vcs_p4_revert_unchanged, .vcs_p4_revert, .vcs_p4_move }) |key| {
        try bench.onHeading("Change 1234");
        bench.base.forgetRequests();
        try bench.act(key);
        try testing.expect(bench.told(refused));
        try testing.expectEqual(@as(?Bench.Presented, null), bench.base.dialog());
        try testing.expectEqual(@as(usize, 0), bench.queued(&storage).len);
        try testing.expect(text_editor.tableOf(&bench.base.tables, p4_change.message_buffer) == null);
    }
    // A refresh before C-c C-c that finds more opened files than the panel keeps submits nothing.
    setOpenedSeen(&bench, 4);
    try bench.onHeading("Change 1234");
    bench.base.forgetRequests();
    try bench.act(Msg.vcs_p4_submit);
    bench.applyText();
    try bench.act(p4_change.Msg.vcs_p4_message_finish);
    var many: std.Io.Writer.Allocating = .init(bench.base.arena.allocator());
    try many.writer.writeAll(opened_said);
    for (0..p4_status.max_files) |index| {
        try many.writer.print("... depotFile //depot/main/more/{d}.zig\n... clientFile /work/repo/more/{d}.zig\n... action edit\n... change 1260\n... type text\n\n", .{ index, index });
    }
    try bench.answerLists(pending_said, many.written());
    try testing.expectError(error.NotQueued, bench.job(.command));
    try testing.expect(bench.toldBeginning("Not every opened file is listed (4 are not), so nothing was submitted"));
    try testing.expect(text_editor.tableOf(&bench.base.tables, p4_change.message_buffer) != null);
    setOpenedSeen(&bench, 10);

    // One file listed is acted on as ever: `k` asks.
    try bench.onFile("//depot/main/b.zig", "1234");
    bench.base.forgetRequests();
    try bench.act(Msg.vcs_p4_revert);
    try testing.expect(bench.base.dialog() != null);
}

test "vcs p4: fstat ending non-zero with no record while changes read is a workspace with nothing opened" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try bench.act(Msg.vcs_p4_status);
    const info = try bench.job(.info);
    bench.base.forgetRequests();
    try bench.answer(info, 0, info_said);
    var jobs: [4]runner.Job = undefined;
    for (&jobs, [_]p4_status.Purpose{ .pending, .shelved_changes, .opened, .submitted }) |*slot, purpose| slot.* = try bench.job(purpose);
    bench.base.forgetRequests();
    try bench.answer(jobs[0], 0, pending_said);
    try bench.answer(jobs[1], 0, "");
    _ = try bench.base.finish(jobs[2], 1, "", "//bruno_ws/... - file(s) not opened on this client.\n");
    bench.run();
    try bench.answer(jobs[3], 0, submitted_said);
    try testing.expectEqual(document_sources.SourceState.ok, bench.sourceState("vcs-p4.opened"));
    try testing.expectEqualStrings("", bench.value("vcs-p4.note").?);
    try testing.expectEqualStrings("0", bench.value("vcs-p4.default-count").?);
    // Another error on its errors, alone: a failure.
    bench.base.forgetRequests();
    try bench.act(Msg.vcs_p4_refresh);
    for (&jobs, [_]p4_status.Purpose{ .pending, .shelved_changes, .opened, .submitted }) |*slot, purpose| slot.* = try bench.job(purpose);
    bench.base.forgetRequests();
    try bench.answer(jobs[0], 0, pending_said);
    try bench.answer(jobs[1], 0, "");
    _ = try bench.base.finish(jobs[2], 1, "", "Perforce client error: Connect to server failed\n");
    bench.run();
    try bench.answer(jobs[3], 0, submitted_said);
    try testing.expectEqual(document_sources.SourceState.unread, bench.sourceState("vcs-p4.opened"));
    // The session check after it answers: signed in.
    const session_info = try bench.job(.session_info);
    const login = try bench.job(.login_status);
    bench.base.forgetRequests();
    try bench.answer(session_info, 0, info_said);
    try bench.answer(login, 0, "");
    // The warning beside another error: a failure.
    bench.base.forgetRequests();
    try bench.act(Msg.vcs_p4_refresh);
    for (&jobs, [_]p4_status.Purpose{ .pending, .shelved_changes, .opened, .submitted }) |*slot, purpose| slot.* = try bench.job(purpose);
    bench.base.forgetRequests();
    try bench.answer(jobs[0], 0, pending_said);
    try bench.answer(jobs[1], 0, "");
    _ = try bench.base.finish(jobs[2], 1, "", "//bruno_ws/... - file(s) not opened on this client.\nPerforce client error: Connect to server failed\n");
    bench.run();
    try bench.answer(jobs[3], 0, submitted_said);
    try testing.expectEqual(document_sources.SourceState.unread, bench.sourceState("vcs-p4.opened"));
    const session_info_again = try bench.job(.session_info);
    const login_again = try bench.job(.login_status);
    bench.base.forgetRequests();
    try bench.answer(session_info_again, 0, info_said);
    try bench.answer(login_again, 0, "");
    // When changes failed too, it is a failure.
    bench.base.forgetRequests();
    try bench.act(Msg.vcs_p4_refresh);
    for (&jobs, [_]p4_status.Purpose{ .pending, .shelved_changes, .opened, .submitted }) |*slot, purpose| slot.* = try bench.job(purpose);
    bench.base.forgetRequests();
    try bench.answer(jobs[0], 1, "");
    try bench.answer(jobs[1], 0, "");
    try bench.answer(jobs[2], 1, "");
    try bench.answer(jobs[3], 0, submitted_said);
    try testing.expectEqual(document_sources.SourceState.unread, bench.sourceState("vcs-p4.opened"));
}

test "vcs p4: info that fails says no server answered; a late answer after C-g is dropped; a failed describe is told" {
    var bench: Bench = .{};
    try bench.init();
    defer bench.deinit();
    try bench.act(Msg.vcs_p4_status);
    const info = try bench.job(.info);
    bench.base.forgetRequests();
    try bench.answer(info, 1, "");
    try testing.expect(std.mem.startsWith(u8, bench.value("vcs-p4.note").?, "p4 info failed: no Perforce server answered"));
    // `g`, then `C-g` while `info` runs: its late answer changes nothing.
    try bench.act(Msg.vcs_p4_refresh);
    const again = try bench.job(.info);
    try bench.base.markRunning(again);
    bench.base.forgetRequests();
    try bench.act(Msg.vcs_p4_give_up);
    try bench.answer(again, 0, info_said);
    var jobs: [8]runner.Job = undefined;
    try testing.expectEqual(@as(usize, 0), bench.queued(&jobs).len);
    try testing.expectEqualStrings("", bench.value("vcs-p4.client").?);
    // A submitted change whose `describe` fails says so in the diff panel.
    try bench.refreshFromInfo();
    try bench.onHeading("Recent submitted changes");
    try bench.act(Msg.vcs_p4_next);
    bench.base.forgetRequests();
    try bench.act(Msg.vcs_p4_visit);
    const describe = try bench.job(.describe);
    try testing.expectEqualStrings("p4\x1f-c\x1fbruno_ws\x1fdescribe\x1f-du\x1f1200", describe.argv);
    bench.base.forgetRequests();
    try bench.answer(describe, 1, "");
    try testing.expect(bench.told("p4 describe failed; $ shows why"));
    const built = try p4_diff.build(bench.base.arena.allocator(), p4_diff.sourcesOf(&bench.base.tables).?);
    try testing.expect(std.mem.startsWith(u8, built.lines[1].text, "Not shown: p4 describe failed"));
}

test "vcs p4: reconcile writes the project's directory encoded, and offers to open into the changelist it was asked on" {
    var bench: Bench = .{ .base = .{ .working_directory = "/work/repo/v@2" } };
    try bench.init();
    defer bench.deinit();
    try bench.open();
    try bench.onHeading("Change 1240");
    bench.base.forgetRequests();
    try bench.act(Msg.vcs_p4_reconcile);
    const preview = try bench.job(.command);
    try testing.expectEqualStrings("p4\x1f-ztag\x1f-c\x1fbruno_ws\x1freconcile\x1f-n\x1f/work/repo/v%402/...", preview.argv);
    // A dialog asked while the preview runs does not change where it opens.
    try bench.onHeading("Change 1234");
    try bench.act(Msg.vcs_p4_revert);
    bench.base.forgetRequests();
    try bench.answer(preview, 0, "//depot/main/new.zig#1 - opened for add\n");
    try testing.expectEqualStrings("Open what p4 reconcile found into change 1240?", bench.base.dialog().?.completions.title);
}
