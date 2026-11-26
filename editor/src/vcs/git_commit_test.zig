//! Tests of vcs-git's commits (`git_commit.zig`), run on the panel's bench (`git_status_test.zig`)
//! with the text editor beside it, whose requests are applied as after a frame: the commit menu's
//! answer is given as the menu gives it, the message is typed into the buffer, and each job's
//! answer as the runner gives it. One test commits and amends through the panel's own path in a
//! real git repository (skipped on Windows and where `git` is not on `PATH`).

const std = @import("std");
const builtin = @import("builtin");
const mesha = @import("mesha");
const mesha_runtime = @import("mesha_runtime");
const Atom = mesha.Atom;
const Table = mesha.Table;
const plugin = mesha.plugin;
const sequencer = mesha.sequencer;
const ui = mesha.ui;
const editor_sequencer = @import("../editor_sequencer.zig");
const transient = @import("../transient.zig");
const text_panel = @import("../text_panel.zig");
const editor_state = @import("../state.zig");
const action_palette = @import("../action_palette.zig");
const shared = @import("../text_editor.zig");
const modes = @import("../modes.zig");
const git = @import("git.zig");
const runner = @import("runner.zig");
const git_status = @import("git_status.zig");
const git_commit = @import("git_commit.zig");
const status_test = @import("git_status_test.zig");
const Bench = status_test.Bench;
const testing = std.testing;
const text_editor = plugin.text_editor_api;

/// The panel's bench with the text editor, whose requests are applied when a test says.
pub const Desk = struct {
    bench: Bench = .{},
    editors: mesha_runtime.text_editor.TextEditor = undefined,
    /// What the panel told, in order, kept as the text editor's requests are applied.
    said: std.ArrayList([]const u8) = .empty,

    pub fn init(desk: *Desk) !void {
        try desk.bench.init();
        const scratch = try desk.bench.memory.tableScratchAllocator();
        try text_panel.ensure(scratch, &desk.bench.atoms, &desk.bench.tables);
        try mesha_runtime.text_editor.ensure(scratch, &desk.bench.atoms, &desk.bench.tables);
        try desk.editors.init(testing.allocator, &desk.bench.memory, testing.io);
    }

    pub fn deinit(desk: *Desk) void {
        desk.editors.deinit(&desk.bench.tables);
        desk.bench.deinit();
    }

    /// The text editor applies the requests waiting, as after a frame; what the panel told is
    /// kept first.
    pub fn applyText(desk: *Desk) !void {
        const allocator = desk.bench.arena.allocator();
        var waiting: [32][]const u8 = undefined;
        for (desk.bench.told(&waiting)) |line| try desk.said.append(allocator, try allocator.dupe(u8, line));
        mesha_runtime.text_editor.applyCommands(&desk.bench.memory, &desk.bench.atoms, &desk.bench.tables, &desk.editors);
    }

    /// Whether the panel told `sentence`, before or since the text editor last applied.
    pub fn told(desk: *Desk, sentence: []const u8) bool {
        var waiting: [32][]const u8 = undefined;
        for (desk.bench.told(&waiting)) |line| {
            if (std.mem.eql(u8, line, sentence)) return true;
        }
        for (desk.said.items) |line| {
            if (std.mem.eql(u8, line, sentence)) return true;
        }
        return false;
    }

    /// The action `tag` invoked, as the actions host delivers it, and the panel's run.
    pub fn act(desk: *Desk, tag: git_commit.Msg) !void {
        const inbox = sequencer.inboxOf(git_status.system());
        try sequencer.deliverMessage(&desk.bench.tables, inbox, Atom.from(tag), &.{}, &.{});
        desk.bench.run();
    }

    /// `c`, then `keys` typed in the menu it shows, the last choosing a command.
    pub fn commit(desk: *Desk, keys: []const u8) !void {
        try desk.act(.vcs_git_commit_menu);
        const requests = transient.Requests.of(&desk.bench.memory, &desk.bench.tables, transient.requests_table_name);
        var sent: [4]transient.Request = undefined;
        const presented = requests.peek(&sent);
        try testing.expectEqual(@as(usize, 1), presented.len);
        const presenting = presented[0].present;
        try testing.expect(presenting.menu == &git_commit.menu);
        var state = presenting.state;
        var chosen_id: ?u32 = null;
        for (0..keys.len) |index| {
            switch (ui.transient.press(&git_commit.menu, &state, keys[index .. index + 1])) {
                .chosen => |id| chosen_id = id,
                .pending, .toggled, .unbound, .wants_value, .menu => {},
            }
        }
        const reply = presenting.reply;
        requests.reset();
        const chosen: transient.Chosen = .{ .id = chosen_id.?, .cancelled = 0, .state = state };
        try sequencer.deliverMessage(&desk.bench.tables, reply.inbox, reply.tag, reply.user_data.bytes, std.mem.asBytes(&chosen));
        desk.bench.run();
    }

    /// The person writes `text` in the message buffer, in place of what it held.
    pub fn write(desk: *Desk, text: []const u8) void {
        desk.editors.apply(&desk.bench.tables, .{ .set_text = .{ .buffer = git_commit.message_buffer, .text = text } });
        desk.editors.publish(&desk.bench.tables);
    }

    /// The message buffer's text, or null when it is not open.
    pub fn message(desk: *Desk) !?[]const u8 {
        if (text_editor.tableOf(&desk.bench.tables, git_commit.message_buffer) == null) return null;
        return try shared.textOf(&desk.bench.tables, git_commit.message_buffer);
    }

    /// The text editor's requests waiting, in order.
    fn textRequests(desk: *Desk, into: []text_editor.CmdPayload) []text_editor.CmdPayload {
        return text_editor.Requests.of(&desk.bench.memory, &desk.bench.tables, text_editor.commands_table_name).peek(into);
    }

    /// Whether the text editor was asked to close the message buffer.
    fn closeAsked(desk: *Desk) bool {
        var sent: [32]text_editor.CmdPayload = undefined;
        for (desk.textRequests(&sent)) |request| switch (request) {
            .close => |buffer| if (buffer == git_commit.message_buffer) return true,
            else => {},
        };
        return false;
    }

    /// The text the message buffer was set to; null when none was asked.
    fn textSet(desk: *Desk) ?[]const u8 {
        var sent: [32]text_editor.CmdPayload = undefined;
        for (desk.textRequests(&sent)) |request| switch (request) {
            .set_text => |set| if (set.buffer == git_commit.message_buffer) return set.text,
            .replace_range => |replaced| if (replaced.buffer == git_commit.message_buffer) return replaced.utf8,
            else => {},
        };
        return null;
    }

    /// Opens the message buffer with `c c`, as the text editor makes it, and the panel's run that
    /// sees it.
    fn openMessage(desk: *Desk) !void {
        try desk.commit("c");
        try desk.applyText();
        desk.bench.run();
        try testing.expectEqualStrings("", (try desk.message()).?);
    }

    /// The commit being written's phase.
    pub fn phase(desk: *Desk) git_commit.Phase {
        const pending = desk.bench.tables.findByName(Atom.from(git_commit.pending_table_name)).?;
        var rows = pending.readQuery(struct { phase: *u8 });
        return @enumFromInt(rows.next().?.view.phase.*);
    }
};

/// The rows `showBuffer` and `setBufferMode` left for the text panels: the message buffer asked
/// for in the other window, its windows' mode `vcs_message`.
fn expectShownWithMode(desk: *Desk) !void {
    const requests = desk.bench.tables.findByName(Atom.from(text_panel.show_requests_table_name)).?;
    var shown = requests.readQuery(struct { buffer: *Atom, place: *u8 });
    const request = shown.next().?.view;
    try testing.expectEqual(git_commit.message_buffer, request.buffer.*);
    try testing.expectEqual(@as(u8, @intFromEnum(text_panel.Place.other_window)), request.place.*);
    const buffer_modes = desk.bench.tables.findByName(Atom.from(text_panel.buffer_modes_table_name)).?;
    var moded = buffer_modes.readQuery(struct { buffer: *Atom, mode: *Atom });
    const row = moded.next().?.view;
    try testing.expectEqual(git_commit.message_buffer, row.buffer.*);
    try testing.expectEqual(modes.vcs_message, row.mode.*);
}

/// The refresh queued since the requests were last forgotten, answered with the status `status`
/// and the recent commits; the refresh jobs it asks after, answered alike. A command its end
/// queues is left, the only request since they were last forgotten.
pub fn answerRefresh(bench: *Bench, status: []const u8) !void {
    for (0..3) |_| {
        var storage: [8]runner.Job = undefined;
        const queued = bench.queued(&storage);
        var jobs: [8]runner.Job = undefined;
        var count: usize = 0;
        for (queued) |job| switch (Bench.purposeOf(job)) {
            .status, .recent, .operation, .root => {
                jobs[count] = job;
                count += 1;
            },
            else => {},
        };
        if (count == 0) return;
        bench.forgetRequests();
        for (jobs[0..count]) |job| {
            const said: []const u8 = switch (Bench.purposeOf(job)) {
                .status => status,
                .recent => status_test.recent_commits,
                else => "",
            };
            _ = try bench.finish(job, 0, said, "");
        }
        bench.run();
    }
}

/// `C-c C-c` on an amend or a reword: the status it reads first answered with `HEAD` where it
/// was (`status_test.changed_status`), so the commit is queued.
fn finishVerified(desk: *Desk) !void {
    desk.bench.forgetRequests();
    try desk.act(.vcs_message_finish);
    try testing.expectEqual(git_commit.Phase.verifying, desk.phase());
    var storage: [8]runner.Job = undefined;
    _ = try Bench.jobFor(desk.bench.queued(&storage), .status);
    try answerRefresh(&desk.bench, status_test.changed_status);
}

/// `job` with its text copied into the bench's arena, so it outlives the requests forgotten.
fn keptJob(bench: *Bench, job: runner.Job) !runner.Job {
    const allocator = bench.arena.allocator();
    var kept = job;
    kept.argv = try allocator.dupe(u8, job.argv);
    kept.input = try allocator.dupe(u8, job.input);
    kept.environment = try allocator.dupe(u8, job.environment);
    kept.directory = try allocator.dupe(u8, job.directory);
    kept.shown = try allocator.dupe(u8, job.shown);
    kept.owner.user_data.bytes = try allocator.dupe(u8, job.owner.user_data.bytes);
    return kept;
}

fn queuedCount(desk: *Desk) usize {
    var storage: [8]runner.Job = undefined;
    return desk.bench.queued(&storage).len;
}

test "vcs git commit: c c shows the message buffer, and C-c C-c commits its text on standard input" {
    var desk: Desk = .{};
    try desk.init();
    defer desk.deinit();
    try status_test.openAnswered(&desk.bench);
    try desk.commit("c");
    // The buffer made and emptied, shown in the other window with its mode; no job yet.
    var sent: [32]text_editor.CmdPayload = undefined;
    const created = for (desk.textRequests(&sent)) |request| switch (request) {
        .create => |create| if (create.buffer == git_commit.message_buffer) break create,
        else => {},
    } else return error.NotCreated;
    try testing.expectEqualStrings(git_commit.message_name, created.name);
    try testing.expectEqual(text_editor.Access.edit, created.access);
    try testing.expectEqualStrings("", desk.textSet().?);
    try expectShownWithMode(&desk);
    try testing.expectEqual(@as(usize, 0), queuedCount(&desk));
    try desk.applyText();
    desk.bench.run();

    const message = "Add a line\n\nBecause.\n";
    desk.write(message);
    try desk.act(.vcs_message_finish);
    const job = try status_test.expectCommand(&desk.bench, .{ .commit = .{ .kind = .new } }, message);
    try testing.expectEqualStrings("git commit -F -", job.shown);
    try testing.expect(!desk.closeAsked());
    try desk.applyText();

    // It ends well: told, the buffer closed, and the refresh asks for the operation.
    _ = try desk.bench.finish(job, 0, "", "");
    desk.bench.forgetRequests();
    desk.bench.run();
    try testing.expect(desk.told("Committed: Add a line"));
    try testing.expect(desk.closeAsked());
    var storage: [8]runner.Job = undefined;
    const refresh = desk.bench.queued(&storage);
    try testing.expectEqual(@as(usize, 3), refresh.len);
    _ = try Bench.jobFor(refresh, .operation);
    try testing.expectEqual(git_commit.Phase.none, desk.phase());
    try desk.applyText();
    try testing.expect(try desk.message() == null);
}

/// The text panels' system runs, as in the editor's frame, after the text editor's requests are
/// applied.
fn runTextPanels(desk: *Desk) !void {
    try desk.applyText();
    const solo = sequencer.Solo.of("vcs_git_text_test", text_panel.system());
    editor_sequencer.run(&desk.bench.memory, &desk.bench.atoms, &desk.bench.tables, &solo.sequencer(), null);
    desk.bench.tables.reclaimPayloads();
}

/// The requests waiting for the panels system.
fn panelRequests(desk: *Desk, into: []plugin.panels.CmdPayload) []plugin.panels.CmdPayload {
    const requests = plugin.panels.Requests.of(&desk.bench.memory, &desk.bench.tables, plugin.panels.commands_table_name);
    return requests.peek(into);
}

test "vcs git commit: C-c C-c in a window that showed a file gives the focus back, naming no panel" {
    var desk: Desk = .{};
    try desk.init();
    defer desk.deinit();
    const scratch = try desk.bench.memory.tableScratchAllocator();
    try editor_state.ensureViewFocus(scratch, &desk.bench.atoms, &desk.bench.tables);
    try mesha.input.ensureTables(scratch, &desk.bench.atoms, &desk.bench.tables);
    try action_palette.ensure(scratch, &desk.bench.atoms, &desk.bench.tables);
    const alone: sequencer.Sequencer = .{ .name = "vcs_git_text_test", .steps = &.{.{ .system = text_panel.system() }} };
    try sequencer.ensureInboxes(scratch, &desk.bench.atoms, &desk.bench.tables, &alone);
    try status_test.openAnswered(&desk.bench);

    // A text window shows a file's buffer.
    const file = Atom.from("notes.txt");
    desk.editors.apply(&desk.bench.tables, .{ .create = .{ .buffer = file, .lines = .multi, .name = "notes.txt" } });
    desk.editors.publish(&desk.bench.tables);
    text_panel.showBuffer(&desk.bench.tables, file, .this_window);
    try runTextPanels(&desk);

    // From vcs-git, `c c` shows the message in that window, in place of the file.
    editor_state.setViewFocus(&desk.bench.tables, &desk.bench.atoms, git_status.panel);
    try desk.commit("c");
    try runTextPanels(&desk);
    desk.bench.run();
    try testing.expectEqualStrings("", (try desk.message()).?);
    desk.write("Add a line\n");
    try desk.act(.vcs_message_finish);
    const job = try status_test.expectCommand(&desk.bench, .{ .commit = .{ .kind = .new } }, "Add a line\n");

    // It ends well: the buffer closes, its window shows the file again, and the panel before
    // it has the focus back. Nothing names vcs-git.
    const panel_requests = plugin.panels.Requests.of(&desk.bench.memory, &desk.bench.tables, plugin.panels.commands_table_name);
    panel_requests.reset();
    _ = try desk.bench.finish(job, 0, "", "");
    desk.bench.run();
    try testing.expect(desk.closeAsked());
    try runTextPanels(&desk);
    try testing.expect(try desk.message() == null);
    var sent: [16]plugin.panels.CmdPayload = undefined;
    var previous_asked: usize = 0;
    for (panelRequests(&desk, &sent)) |request| switch (request) {
        .focus_previous => |previous| {
            try testing.expect(previous.from != git_status.panel);
            previous_asked += 1;
        },
        .focus => |focus| try testing.expect(focus.id != git_status.panel),
        else => {},
    };
    try testing.expectEqual(@as(usize, 1), previous_asked);
}

test "vcs git commit: c a fills the message from HEAD" {
    var desk: Desk = .{};
    try desk.init();
    defer desk.deinit();
    try status_test.openAnswered(&desk.bench);
    try desk.commit("a");
    // HEAD's message is asked first, and nothing is shown until it answers.
    var storage: [8]runner.Job = undefined;
    const jobs = desk.bench.queued(&storage);
    try testing.expectEqual(@as(usize, 1), jobs.len);
    try testing.expectEqual(git_status.Purpose.head_message, Bench.purposeOf(jobs[0]));
    try status_test.expectArgv(jobs[0], .head_message);
    try testing.expect(desk.textSet() == null);
    _ = try desk.bench.finish(jobs[0], 0, "Teach the panel its sections\n\nWith a body.\n\n", "");
    desk.bench.run();
    try testing.expectEqualStrings("Teach the panel its sections\n\nWith a body.", desk.textSet().?);
    try expectShownWithMode(&desk);
    try desk.applyText();
    desk.bench.run();
    desk.bench.forgetRequests();

    try finishVerified(&desk);
    _ = try status_test.expectCommand(&desk.bench, .{ .commit = .{ .kind = .amend } }, "Teach the panel its sections\n\nWith a body.");
}

/// `c w` begun with `HEAD` as `changed_status` says, its message loaded and shown.
fn rewordBegun(desk: *Desk) !void {
    try status_test.openAnswered(&desk.bench);
    try desk.commit("w");
    var storage: [8]runner.Job = undefined;
    _ = try desk.bench.finish(try Bench.jobFor(desk.bench.queued(&storage), .head_message), 0, "Old words\n", "");
    desk.bench.run();
    try desk.applyText();
    desk.bench.run();
    desk.bench.forgetRequests();
    desk.write("New words\n");
}

/// `changed_status` with `HEAD` at another commit, as after a pull or a switch.
const moved_status = "# branch.oid 9999999999999999999999999999999999999999\x00# branch.head main\x00";

test "vcs git commit: C-c C-c on a reword whose HEAD the status already shows moved runs nothing and keeps the buffer" {
    var desk: Desk = .{};
    try desk.init();
    defer desk.deinit();
    try rewordBegun(&desk);
    // A pull ran meanwhile, and a refresh read it.
    desk.bench.forgetRequests();
    try desk.bench.act(.vcs_git_refresh);
    try answerRefresh(&desk.bench, moved_status);
    try desk.applyText();
    desk.bench.forgetRequests();
    try desk.act(.vcs_message_finish);
    try testing.expectEqual(@as(usize, 0), queuedCount(&desk));
    try testing.expect(desk.told("HEAD moved since the message was begun: c a / c w asks again; the buffer is kept"));
    try testing.expectEqual(git_commit.Phase.editing, desk.phase());
    try testing.expect(!desk.closeAsked());
    try desk.applyText();
    try testing.expectEqualStrings("New words\n", (try desk.message()).?);
}

test "vcs git commit: C-c C-c on an amend reads the status first: HEAD moved refuses and keeps the buffer, HEAD in place amends" {
    var desk: Desk = .{};
    try desk.init();
    defer desk.deinit();
    try rewordBegun(&desk);
    // The status held is stale: the refresh `C-c C-c` asks shows HEAD at another commit.
    try desk.act(.vcs_message_finish);
    try testing.expectEqual(git_commit.Phase.verifying, desk.phase());
    var storage: [8]runner.Job = undefined;
    _ = try Bench.jobFor(desk.bench.queued(&storage), .status);
    try answerRefresh(&desk.bench, moved_status);
    try status_test.expectNoCommand(&desk.bench);
    try testing.expect(desk.told("HEAD moved since the message was begun: c a / c w asks again; the buffer is kept"));
    try testing.expectEqual(git_commit.Phase.editing, desk.phase());
    try testing.expect(!desk.closeAsked());
    try desk.applyText();
    try testing.expectEqualStrings("New words\n", (try desk.message()).?);

    // HEAD back where the message was begun (a reset, say), and read: the reword runs, with
    // the text.
    desk.bench.forgetRequests();
    try desk.bench.act(.vcs_git_refresh);
    try answerRefresh(&desk.bench, status_test.changed_status);
    desk.bench.forgetRequests();
    try desk.act(.vcs_message_finish);
    try answerRefresh(&desk.bench, status_test.changed_status);
    _ = try status_test.expectCommand(&desk.bench, .{ .commit = .{ .kind = .reword } }, "New words\n");
    try testing.expectEqual(git_commit.Phase.running, desk.phase());
}

test "vcs git commit: C-c C-c on a reword while a command runs waits for the refresh after that command" {
    var desk: Desk = .{};
    try desk.init();
    defer desk.deinit();
    try rewordBegun(&desk);
    // A file staged: its command runs.
    try desk.bench.actOn(.unstaged, "a.txt", .vcs_git_stage);
    var storage: [8]runner.Job = undefined;
    const stage = try keptJob(&desk.bench, try Bench.jobFor(desk.bench.queued(&storage), .command));
    desk.bench.forgetRequests();
    try desk.act(.vcs_message_finish);
    // The refresh ends while the command runs: nothing yet.
    try answerRefresh(&desk.bench, status_test.changed_status);
    try status_test.expectNoCommand(&desk.bench);
    try testing.expectEqual(git_commit.Phase.verifying, desk.phase());
    // The command ends, and the refresh it asks finds HEAD in place: the reword runs.
    desk.bench.forgetRequests();
    _ = try desk.bench.finish(stage, 0, "", "");
    desk.bench.run();
    try answerRefresh(&desk.bench, status_test.changed_status);
    _ = try status_test.expectCommand(&desk.bench, .{ .commit = .{ .kind = .reword } }, "New words\n");
}

test "vcs git commit: C-g while C-c C-c reads the status runs nothing and keeps the message being written" {
    var desk: Desk = .{};
    try desk.init();
    defer desk.deinit();
    try rewordBegun(&desk);
    try desk.act(.vcs_message_finish);
    try testing.expectEqual(git_commit.Phase.verifying, desk.phase());
    try desk.bench.act(.vcs_git_give_up);
    desk.bench.run();
    try testing.expectEqual(git_commit.Phase.editing, desk.phase());
    try testing.expect(!desk.closeAsked());
    try status_test.expectNoCommand(&desk.bench);
}

test "vcs git commit: c e commits with no buffer" {
    var desk: Desk = .{};
    try desk.init();
    defer desk.deinit();
    try status_test.openAnswered(&desk.bench);
    try desk.commit("e");
    const job = try status_test.expectCommand(&desk.bench, .{ .commit = .{ .kind = .extend } }, "");
    try testing.expectEqualStrings("git commit --amend --no-edit", job.shown);
    try testing.expect(desk.textSet() == null);
    try testing.expectEqual(git_commit.Phase.none, desk.phase());
}

test "vcs git commit: an empty message is refused" {
    var desk: Desk = .{};
    try desk.init();
    defer desk.deinit();
    try status_test.openAnswered(&desk.bench);
    try desk.openMessage();
    desk.write("  \n\n\t\n");
    try desk.act(.vcs_message_finish);
    try testing.expect(desk.told("The message is empty"));
    try testing.expectEqual(@as(usize, 0), queuedCount(&desk));
    try testing.expectEqual(git_commit.Phase.editing, desk.phase());
    try testing.expect(!desk.closeAsked());
}

test "vcs git commit: c c with nothing staged tells and opens nothing, and -a commits all" {
    var desk: Desk = .{};
    try desk.init();
    defer desk.deinit();
    try status_test.openAnsweredWith(&desk.bench, status_test.unstaged_status);
    try desk.commit("c");
    try testing.expect(desk.told("Nothing staged; s stages, or c -a c commits all changes"));
    try testing.expect(desk.textSet() == null);
    try testing.expectEqual(@as(usize, 0), queuedCount(&desk));
    try testing.expectEqual(git_commit.Phase.none, desk.phase());

    // The menu's switches reach the command line: `-a` is `--all`, `-s` `--signoff`.
    try desk.commit("-a-sc");
    try desk.applyText();
    desk.bench.run();
    desk.write("Everything\n");
    try desk.act(.vcs_message_finish);
    _ = try status_test.expectCommand(&desk.bench, .{ .commit = .{ .kind = .new, .arguments = "--all\x1f--signoff\x1f" } }, "Everything\n");
}

test "vcs git commit: w passes --amend --only" {
    var desk: Desk = .{};
    try desk.init();
    defer desk.deinit();
    try status_test.openAnswered(&desk.bench);
    try desk.commit("w");
    var storage: [8]runner.Job = undefined;
    const jobs = desk.bench.queued(&storage);
    _ = try desk.bench.finish(try Bench.jobFor(jobs, .head_message), 0, "Old words\n", "");
    desk.bench.run();
    try desk.applyText();
    desk.bench.run();
    desk.bench.forgetRequests();
    desk.write("New words\n");
    try finishVerified(&desk);
    const job = try status_test.expectCommand(&desk.bench, .{ .commit = .{ .kind = .reword } }, "New words\n");
    try testing.expect(std.mem.endsWith(u8, job.argv, "commit\x1f-F\x1f-\x1f--amend\x1f--only"));
}

test "vcs git commit: C-c C-k runs nothing, keeps the text, and M-p brings it back" {
    var desk: Desk = .{};
    try desk.init();
    defer desk.deinit();
    try status_test.openAnswered(&desk.bench);
    try desk.openMessage();
    desk.write("Draft one\n");
    try desk.act(.vcs_message_cancel);
    try testing.expect(desk.told("Commit cancelled"));
    try testing.expectEqual(@as(usize, 0), queuedCount(&desk));
    try testing.expect(desk.closeAsked());
    try testing.expectEqual(git_commit.Phase.none, desk.phase());
    try desk.applyText();
    try testing.expect(try desk.message() == null);

    // Written again, `M-p` brings the draft given up back, and `M-n` what was being written.
    try desk.openMessage();
    desk.write("Second\n");
    try desk.act(.vcs_message_previous_message);
    try testing.expectEqualStrings("Draft one\n", desk.textSet().?);
    try desk.applyText();
    try testing.expectEqualStrings("Draft one\n", (try desk.message()).?);
    try desk.act(.vcs_message_previous_message);
    try testing.expect(desk.told("No earlier message"));
    try desk.act(.vcs_message_next_message);
    try testing.expectEqualStrings("Second\n", desk.textSet().?);
    try desk.applyText();
    try testing.expectEqualStrings("Second\n", (try desk.message()).?);
    try desk.act(.vcs_message_next_message);
    try testing.expect(desk.told("No later message"));
}

test "vcs git commit: a commit that fails keeps the buffer and its text" {
    var desk: Desk = .{};
    try desk.init();
    defer desk.deinit();
    try status_test.openAnswered(&desk.bench);
    try desk.openMessage();
    desk.write("Refused by a hook\n");
    try desk.act(.vcs_message_finish);
    const job = try status_test.expectCommand(&desk.bench, .{ .commit = .{ .kind = .new } }, "Refused by a hook\n");
    // A second C-c C-c while it runs.
    try desk.act(.vcs_message_finish);
    try testing.expect(desk.told("The commit is still running"));
    try desk.applyText();
    _ = try desk.bench.finish(job, 1, "", "the hook said no\n");
    desk.bench.run();
    try testing.expect(desk.told("git commit failed; $ shows why"));
    try testing.expect(!desk.closeAsked());
    try testing.expectEqual(git_commit.Phase.editing, desk.phase());
    try desk.applyText();
    try testing.expectEqualStrings("Refused by a hook\n", (try desk.message()).?);
    desk.bench.forgetRequests();
    // Tried again, with the text as it was.
    try desk.act(.vcs_message_finish);
    _ = try status_test.expectCommand(&desk.bench, .{ .commit = .{ .kind = .new } }, "Refused by a hook\n");
}

test "vcs git commit: f away from a commit tells, and on one makes its fixup" {
    var desk: Desk = .{};
    try desk.init();
    defer desk.deinit();
    try status_test.openAnswered(&desk.bench);
    try desk.commit("f");
    try testing.expect(desk.told("Put the cursor on a commit to fix up"));
    try testing.expectEqual(@as(usize, 0), queuedCount(&desk));

    try desk.bench.placeCursor(try desk.bench.spotOf(.recent, "72f25b6"));
    try desk.commit("f");
    const target = "72f25b65411d1f8a0a15a3f577334b3e0e3a4cc0";
    _ = try status_test.expectCommand(&desk.bench, .{ .commit = .{ .kind = .fixup, .target = target } }, "");
}

test "vcs git commit: a give-up of another job keeps the message being written" {
    var desk: Desk = .{};
    try desk.init();
    defer desk.deinit();
    try status_test.openAnswered(&desk.bench);
    try desk.openMessage();
    desk.write("Still writing\n");
    // A refresh runs, and `C-g` gives it up: the panel's generation moves on.
    try desk.bench.act(.vcs_git_refresh);
    try desk.bench.act(.vcs_git_give_up);
    desk.bench.run();
    try testing.expect(!desk.told("Commit cancelled"));
    try testing.expect(!desk.closeAsked());
    try testing.expectEqual(git_commit.Phase.editing, desk.phase());
    try desk.applyText();
    try testing.expectEqualStrings("Still writing\n", (try desk.message()).?);
}

test "vcs git commit: a give-up while its own job runs ends the commit" {
    var desk: Desk = .{};
    try desk.init();
    defer desk.deinit();
    try status_test.openAnswered(&desk.bench);
    // While HEAD's message is asked: back to none, told.
    try desk.commit("a");
    var storage: [8]runner.Job = undefined;
    try desk.bench.markRunning(desk.bench.queued(&storage)[0]);
    try desk.bench.act(.vcs_git_give_up);
    try testing.expect(desk.told("Commit cancelled"));
    try testing.expectEqual(git_commit.Phase.none, desk.phase());
    try desk.applyText();
    desk.bench.forgetRequests();

    // While the commit runs: it may have been made, and M-p has the message.
    try desk.openMessage();
    desk.write("Maybe made\n");
    try desk.act(.vcs_message_finish);
    try desk.bench.markRunning(desk.bench.queued(&storage)[0]);
    try desk.bench.act(.vcs_git_give_up);
    try testing.expect(desk.told("Gave up waiting for the commit; it may have been made (M-p has the message)"));
    try testing.expect(desk.closeAsked());
    try testing.expectEqual(git_commit.Phase.none, desk.phase());
    try desk.applyText();
    try desk.openMessage();
    try desk.act(.vcs_message_previous_message);
    try testing.expectEqualStrings("Maybe made\n", desk.textSet().?);
}

test "vcs git commit: a message buffer that never opens ends the commit, and c c starts again" {
    var desk: Desk = .{};
    try desk.init();
    defer desk.deinit();
    try status_test.openAnswered(&desk.bench);
    // The text editor refuses to make the buffer: its requests are dropped unapplied.
    try desk.commit("c");
    desk.bench.forgetRequests();
    // Asked again before it gives up, the commit starts over rather than telling it is written.
    try desk.commit("c");
    try testing.expect(!desk.told("A commit message is being written: C-c C-c commits it, C-c C-k gives it up"));
    try testing.expect(desk.textSet() != null);
    desk.bench.forgetRequests();
    for (0..12) |_| desk.bench.run();
    try testing.expect(desk.told("The message buffer could not be opened; close a buffer and try again"));
    try testing.expectEqual(git_commit.Phase.none, desk.phase());
    const buffer_modes = desk.bench.tables.findByName(Atom.from(text_panel.buffer_modes_table_name)).?;
    try testing.expectEqual(@as(u32, 0), buffer_modes.count());
    const requests = desk.bench.tables.findByName(Atom.from(text_panel.show_requests_table_name)).?;
    try testing.expectEqual(@as(u32, 0), requests.count());
    desk.bench.forgetRequests();
    try desk.openMessage();
    try testing.expectEqual(git_commit.Phase.editing, desk.phase());
}

test "vcs git commit: c c over a message being written shows it again with its mode" {
    var desk: Desk = .{};
    try desk.init();
    defer desk.deinit();
    try status_test.openAnswered(&desk.bench);
    try desk.openMessage();
    // The text panels let the buffer's mode go, as they do for one they waited for too long.
    text_panel.setBufferMode(&desk.bench.tables, git_commit.message_buffer, modes.buffer);
    const requests = desk.bench.tables.findByName(Atom.from(text_panel.show_requests_table_name)).?;
    requests.clear();
    try desk.commit("c");
    try testing.expect(desk.told("A commit message is being written: C-c C-c commits it, C-c C-k gives it up"));
    try expectShownWithMode(&desk);
}

test "vcs git commit: w with -a leaves --all out and says so" {
    var desk: Desk = .{};
    try desk.init();
    defer desk.deinit();
    try status_test.openAnswered(&desk.bench);
    try desk.commit("-a-sw");
    try testing.expect(desk.told("Reword changes the message only; --all was left out"));
    var storage: [8]runner.Job = undefined;
    const jobs = desk.bench.queued(&storage);
    _ = try desk.bench.finish(try Bench.jobFor(jobs, .head_message), 0, "Old words\n", "");
    desk.bench.run();
    try desk.applyText();
    desk.bench.run();
    try finishVerified(&desk);
    _ = try status_test.expectCommand(&desk.bench, .{ .commit = .{ .kind = .reword, .arguments = "--signoff\x1f" } }, "Old words");
}

test "vcs git commit: C-c C-c in another repository gives the commit up" {
    var desk: Desk = .{};
    try desk.init();
    defer desk.deinit();
    try status_test.openAnswered(&desk.bench);
    try desk.openMessage();
    desk.write("Somewhere else\n");
    const state = desk.bench.tables.findByName(Atom.from(git_status.state_table_name)).?;
    try state.setString(.{ .row = 0, .generation = state.rowGeneration(0) }, "root", "/work/other");
    try desk.act(.vcs_message_finish);
    try testing.expect(desk.told("The repository changed; the commit was given up (M-p has the message)"));
    try testing.expectEqual(@as(usize, 0), queuedCount(&desk));
    try testing.expectEqual(git_commit.Phase.none, desk.phase());
}

test "vcs git commit: e and f tell as they end well" {
    var desk: Desk = .{};
    try desk.init();
    defer desk.deinit();
    try status_test.openAnswered(&desk.bench);
    try desk.commit("e");
    var storage: [8]runner.Job = undefined;
    _ = try desk.bench.finish(desk.bench.queued(&storage)[0], 0, "", "");
    desk.bench.forgetRequests();
    desk.bench.run();
    try testing.expect(desk.told("Extended HEAD"));
    try desk.applyText();
    desk.bench.forgetRequests();

    try desk.bench.placeCursor(try desk.bench.spotOf(.recent, "72f25b6"));
    try desk.commit("f");
    _ = try desk.bench.finish(desk.bench.queued(&storage)[0], 0, "", "");
    desk.bench.forgetRequests();
    desk.bench.run();
    try testing.expect(desk.told("Made a fixup of 72f25b6"));
}

test "vcs git commit: two fixups queued back to back each tell their own commit" {
    var desk: Desk = .{};
    try desk.init();
    defer desk.deinit();
    try status_test.openAnswered(&desk.bench);
    try desk.bench.placeCursor(try desk.bench.spotOf(.recent, "72f25b6"));
    try desk.commit("f");
    try desk.bench.placeCursor(try desk.bench.spotOf(.recent, "5fa486e"));
    try desk.commit("f");
    var storage: [8]runner.Job = undefined;
    const jobs = desk.bench.queued(&storage);
    try testing.expectEqual(@as(usize, 2), jobs.len);
    desk.bench.forgetRequests();
    _ = try desk.bench.finish(jobs[0], 0, "", "");
    _ = try desk.bench.finish(jobs[1], 0, "", "");
    desk.bench.run();
    try testing.expect(desk.told("Made a fixup of 72f25b6"));
    try testing.expect(desk.told("Made a fixup of 5fa486e"));
}

// ---- against a real git ------------------------------------------------------------------------

/// One frame as the host runs it, with the text editor applying its requests after the run.
pub fn stepReal(desk: *Desk) !void {
    const bench = &desk.bench;
    const processes = bench.processes.?;
    processes.deliver(&bench.tables);
    editor_sequencer.run(&bench.memory, &bench.atoms, &bench.tables, &status_test.with_runner, null);
    mesha_runtime.process.applyCommands(&bench.memory, &bench.atoms, &bench.tables, processes);
    const answers = plugin.app_commands.Requests.of(&bench.memory, &bench.tables, plugin.app_commands.commands_table_name);
    answers.drain(bench, status_test.deliverAnswer);
    try desk.applyText();
    bench.tables.reclaimPayloads();
}

/// Runs frames until the panel has nothing queued or running, and the commit being written is
/// in `phase`; fails after a few seconds.
pub fn settleReal(desk: *Desk, phase: git_commit.Phase) !void {
    for (0..1000) |_| {
        try stepReal(desk);
        const state = desk.bench.tables.findByName(Atom.from(git_status.state_table_name)).?;
        var rows = state.readQuery(struct { refresh_jobs: *u8, commands_running: *u8, answered: *u8 });
        const row = rows.next().?.view;
        const busy = runner.busy(&desk.bench.tables, sequencer.inboxOf(git_status.system()));
        const idle = row.refresh_jobs.* == 0 and row.commands_running.* == 0 and !busy;
        if (row.answered.* == 1 and idle and desk.phase() == phase) return;
        try testing.io.sleep(.fromMilliseconds(5), .awake);
    }
    return error.Timeout;
}

test "vcs git commit: a commit and its amend in a real repository" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var folder = try status_test.repositoryFolder();
    defer folder.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const path_length = try folder.dir.realPath(testing.io, &path_buffer);
    const top = path_buffer[0..path_length];
    // The person's own git configuration (signing, hooks, templates) is kept out: an empty global
    // file beside the repository and no system file, for the test's git and the panel's, which
    // take who commits from the environment.
    try folder.dir.writeFile(testing.io, .{ .sub_path = "gitconfig", .data = "" });
    try folder.dir.createDirPath(testing.io, "repo");
    const repository = try std.fs.path.join(allocator, &.{ top, "repo" });
    const global_config = try std.fs.path.join(allocator, &.{ top, "gitconfig" });
    var environment = try status_test.gitEnvironment();
    defer environment.deinit();
    try environment.put("GIT_CONFIG_GLOBAL", global_config);
    try environment.put("GIT_CONFIG_NOSYSTEM", "1");
    try environment.put("GIT_AUTHOR_NAME", "Test");
    try environment.put("GIT_AUTHOR_EMAIL", "test@example.com");
    try environment.put("GIT_COMMITTER_NAME", "Test");
    try environment.put("GIT_COMMITTER_EMAIL", "test@example.com");
    var repository_dir = try folder.dir.openDir(testing.io, "repo", .{});
    defer repository_dir.close(testing.io);
    _ = status_test.runGit(allocator, &environment, repository, &.{ "init", "-q", "-b", "main" }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    try repository_dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "one\n" });
    _ = try status_test.runGit(allocator, &environment, repository, &.{ "add", "a.txt" });
    _ = try status_test.runGit(allocator, &environment, repository, &.{ "commit", "-q", "-m", "First" });
    try repository_dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "one\ntwo\n" });
    _ = try status_test.runGit(allocator, &environment, repository, &.{ "add", "a.txt" });

    var desk: Desk = .{ .bench = .{ .working_directory = repository } };
    try desk.init();
    defer desk.deinit();
    var processes: mesha_runtime.process.Processes = undefined;
    try status_test.startProcesses(&desk.bench, &processes, &environment);
    defer processes.deinit(&desk.bench.tables);
    try desk.bench.act(.vcs_git_status);
    try settleReal(&desk, .none);

    // `c c`, the message written, `C-c C-c`: one commit more, with that message.
    try desk.commit("c");
    try settleReal(&desk, .editing);
    desk.write("Add a line\n\nBecause.\n");
    try desk.act(.vcs_message_finish);
    try settleReal(&desk, .none);
    try testing.expect(desk.told("Committed: Add a line"));
    const message = try status_test.runGit(allocator, &environment, repository, &.{ "log", "-1", "--format=%B" });
    try testing.expectEqualStrings("Add a line\n\nBecause.\n\n", message);
    const count = try status_test.runGit(allocator, &environment, repository, &.{ "rev-list", "--count", "HEAD" });
    try testing.expectEqualStrings("2\n", count);

    // `c a`: the buffer holds HEAD's message; changed, it replaces the commit's.
    try desk.commit("a");
    try settleReal(&desk, .editing);
    try testing.expectEqualStrings("Add a line\n\nBecause.", (try desk.message()).?);
    desk.write("Add the second line\n\nBecause it was missing.\n");
    try desk.act(.vcs_message_finish);
    try settleReal(&desk, .none);
    const amended = try status_test.runGit(allocator, &environment, repository, &.{ "log", "-1", "--format=%B" });
    try testing.expectEqualStrings("Add the second line\n\nBecause it was missing.\n\n", amended);
    const still = try status_test.runGit(allocator, &environment, repository, &.{ "rev-list", "--count", "HEAD" });
    try testing.expectEqualStrings("2\n", still);
}
